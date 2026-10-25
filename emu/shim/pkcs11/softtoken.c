// Software PKCS#11 token standing in for OP-TEE's libckteec (the device's
// secure-world key store), built on the rootfs' OpenSSL. One slot, no PIN.
// Token objects persist to RMEMU_TOKEN_DB so data xochitl encrypts survives
// restarts. Unimplemented calls log and fail so gaps show up in the log.
#include <p11-kit/pkcs11.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/x509.h>
#include <openssl/ec.h>
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/param_build.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define LOG(...) do { fprintf(stderr, "[rmemu-p11] " __VA_ARGS__); fputc('\n', stderr); } while (0)

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
#define LOCK pthread_mutex_lock(&mu)
#define UNLOCK pthread_mutex_unlock(&mu)
#define RET(rv) do { CK_RV _r = (rv); UNLOCK; return _r; } while (0)

// ---------------------------------------------------------------- objects

struct attr { CK_ATTRIBUTE_TYPE type; CK_ULONG len; unsigned char *val; };
struct obj { CK_OBJECT_HANDLE h; CK_SESSION_HANDLE owner; CK_SLOT_ID slot; int nattrs; struct attr *attrs; struct obj *next; };
static struct obj *objs;
static CK_OBJECT_HANDLE next_handle = 1;

static struct attr *get_attr(struct obj *o, CK_ATTRIBUTE_TYPE t) {
    for (int i = 0; i < o->nattrs; i++) if (o->attrs[i].type == t) return &o->attrs[i];
    return NULL;
}
static void set_attr(struct obj *o, CK_ATTRIBUTE_TYPE t, const void *v, CK_ULONG len) {
    struct attr *a = get_attr(o, t);
    if (!a) { o->attrs = realloc(o->attrs, sizeof *a * (o->nattrs + 1)); a = &o->attrs[o->nattrs++]; a->type = t; a->val = NULL; }
    free(a->val);
    a->val = malloc(len ? len : 1); a->len = len;
    if (len) memcpy(a->val, v, len);
}
static void set_ulong(struct obj *o, CK_ATTRIBUTE_TYPE t, CK_ULONG v) { set_attr(o, t, &v, sizeof v); }
static void set_bool(struct obj *o, CK_ATTRIBUTE_TYPE t, CK_BBOOL v) { set_attr(o, t, &v, 1); }
static CK_ULONG get_ulong(struct obj *o, CK_ATTRIBUTE_TYPE t, CK_ULONG def) {
    struct attr *a = get_attr(o, t);
    return a && a->len == sizeof(CK_ULONG) ? *(CK_ULONG *)a->val : def;
}
static int get_bool(struct obj *o, CK_ATTRIBUTE_TYPE t, int def) {
    struct attr *a = get_attr(o, t);
    return a && a->len >= 1 ? a->val[0] != 0 : def;
}

struct session;
static CK_SLOT_ID session_slot(CK_SESSION_HANDLE h);
static struct obj *new_obj(CK_SESSION_HANDLE owner) {
    struct obj *o = calloc(1, sizeof *o);
    o->h = next_handle++; o->owner = owner; o->slot = session_slot(owner); o->next = objs; objs = o;
    return o;
}
static struct obj *find_obj(CK_OBJECT_HANDLE h) {
    for (struct obj *o = objs; o; o = o->next) if (o->h == h) return o;
    return NULL;
}
static void free_obj(struct obj *o) {
    for (struct obj **p = &objs; *p; p = &(*p)->next) if (*p == o) { *p = o->next; break; }
    for (int i = 0; i < o->nattrs; i++) free(o->attrs[i].val);
    free(o->attrs); free(o);
}
static void apply_template(struct obj *o, CK_ATTRIBUTE_PTR t, CK_ULONG n) {
    for (CK_ULONG i = 0; i < n; i++) set_attr(o, t[i].type, t[i].pValue, t[i].ulValueLen);
}
static int matches(struct obj *o, CK_ATTRIBUTE_PTR t, CK_ULONG n) {
    for (CK_ULONG i = 0; i < n; i++) {
        struct attr *a = get_attr(o, t[i].type);
        if (!a || a->len != t[i].ulValueLen || memcmp(a->val, t[i].pValue, a->len)) return 0;
    }
    return 1;
}

// ---------------------------------------------------------------- persistence

static char db_path[256];

static void save(void) {
    char tmp[300];
    snprintf(tmp, sizeof tmp, "%s.tmp", db_path);
    FILE *f = fopen(tmp, "wb");
    if (!f) { LOG("cannot write %s", tmp); return; }
    for (struct obj *o = objs; o; o = o->next) {
        if (!get_bool(o, CKA_TOKEN, 0)) continue;
        fwrite(&o->h, sizeof o->h, 1, f);
        fwrite(&o->slot, sizeof o->slot, 1, f);
        fwrite(&o->nattrs, sizeof o->nattrs, 1, f);
        for (int i = 0; i < o->nattrs; i++) {
            fwrite(&o->attrs[i].type, sizeof(CK_ULONG), 1, f);
            fwrite(&o->attrs[i].len, sizeof(CK_ULONG), 1, f);
            fwrite(o->attrs[i].val, 1, o->attrs[i].len, f);
        }
    }
    fclose(f);
    rename(tmp, db_path);
}

static void load(void) {
    FILE *f = fopen(db_path, "rb");
    if (!f) return;
    CK_OBJECT_HANDLE h; CK_SLOT_ID slot; int n;
    while (fread(&h, sizeof h, 1, f) == 1 && fread(&slot, sizeof slot, 1, f) == 1 && fread(&n, sizeof n, 1, f) == 1) {
        struct obj *o = new_obj(0);
        o->h = h; o->slot = slot; if (h >= next_handle) next_handle = h + 1;
        for (int i = 0; i < n; i++) {
            CK_ULONG t, len;
            if (fread(&t, sizeof t, 1, f) != 1 || fread(&len, sizeof len, 1, f) != 1) break;
            unsigned char *v = malloc(len ? len : 1);
            if (fread(v, 1, len, f) != len) { free(v); break; }
            set_attr(o, t, v, len); free(v);
        }
    }
    fclose(f);
}

// ---------------------------------------------------------------- sessions

enum { OP_FIND, OP_ENC, OP_DEC, OP_SIGN, OP_VERIFY, OP_DIGEST, NOPS };
struct op {
    int active;
    CK_MECHANISM_TYPE mech;
    struct obj *key;
    unsigned char *param; CK_ULONG param_len;  // copy of mechanism parameter
    unsigned char *buf; size_t len;             // buffered multi-part input
    CK_OBJECT_HANDLE *found; size_t nfound, pos;
};
struct session { CK_SESSION_HANDLE h; CK_SLOT_ID slot; CK_FLAGS flags; struct op ops[NOPS]; struct session *next; };
static struct session *sessions;
static CK_SESSION_HANDLE next_session = 1;
static int initialized, logged_in;

static struct session *get_session(CK_SESSION_HANDLE h) {
    for (struct session *s = sessions; s; s = s->next) if (s->h == h) return s;
    return NULL;
}
static CK_SLOT_ID session_slot(CK_SESSION_HANDLE h) {
    struct session *s = get_session(h);
    return s ? s->slot : 0;
}
static void op_reset(struct op *op) {
    free(op->param); free(op->buf); free(op->found);
    memset(op, 0, sizeof *op);
}
static CK_RV op_begin(struct session *s, int kind, CK_MECHANISM_PTR m, struct obj *key) {
    struct op *op = &s->ops[kind];
    if (op->active) return CKR_OPERATION_ACTIVE;
    op_reset(op);
    op->active = 1; op->key = key;
    if (m) {
        op->mech = m->mechanism;
        if (m->pParameter && m->ulParameterLen) {
            op->param = malloc(m->ulParameterLen); memcpy(op->param, m->pParameter, m->ulParameterLen);
            op->param_len = m->ulParameterLen;
        }
    }
    return CKR_OK;
}
static void op_feed(struct op *op, const void *d, size_t n) {
    op->buf = realloc(op->buf, op->len + n + 1);
    memcpy(op->buf + op->len, d, n); op->len += n;
}

// Standard PKCS#11 "query size, then fill" output convention.
static CK_RV output(const unsigned char *data, size_t n, CK_BYTE_PTR out, CK_ULONG_PTR out_len) {
    if (!out) { *out_len = n; return CKR_OK; }
    if (*out_len < n) { *out_len = n; return CKR_BUFFER_TOO_SMALL; }
    memcpy(out, data, n); *out_len = n;
    return CKR_OK;
}

// ---------------------------------------------------------------- crypto

static const EVP_MD *md_for(CK_MECHANISM_TYPE m) {
    switch (m) {
    case CKM_SHA_1: case CKM_SHA_1_HMAC: case CKM_ECDSA_SHA1: case CKM_SHA1_RSA_PKCS: case CKM_SHA1_RSA_PKCS_PSS: return EVP_sha1();
    case CKM_SHA224: case CKM_SHA224_HMAC: case CKM_ECDSA_SHA224: case CKM_SHA224_RSA_PKCS: return EVP_sha224();
    case CKM_SHA256: case CKM_SHA256_HMAC: case CKM_ECDSA_SHA256: case CKM_SHA256_RSA_PKCS: case CKM_SHA256_RSA_PKCS_PSS: return EVP_sha256();
    case CKM_SHA384: case CKM_SHA384_HMAC: case CKM_ECDSA_SHA384: case CKM_SHA384_RSA_PKCS: case CKM_SHA384_RSA_PKCS_PSS: return EVP_sha384();
    case CKM_SHA512: case CKM_SHA512_HMAC: case CKM_ECDSA_SHA512: case CKM_SHA512_RSA_PKCS: case CKM_SHA512_RSA_PKCS_PSS: return EVP_sha512();
    default: return NULL;
    }
}

static const EVP_CIPHER *aes_cipher(CK_MECHANISM_TYPE m, size_t keylen) {
    int k = (int)keylen * 8;
    switch (m) {
    case CKM_AES_GCM: return k == 128 ? EVP_aes_128_gcm() : k == 192 ? EVP_aes_192_gcm() : EVP_aes_256_gcm();
    case CKM_AES_CBC: case CKM_AES_CBC_PAD: return k == 128 ? EVP_aes_128_cbc() : k == 192 ? EVP_aes_192_cbc() : EVP_aes_256_cbc();
    case CKM_AES_ECB: return k == 128 ? EVP_aes_128_ecb() : k == 192 ? EVP_aes_192_ecb() : EVP_aes_256_ecb();
    case CKM_AES_CTR: return k == 128 ? EVP_aes_128_ctr() : k == 192 ? EVP_aes_192_ctr() : EVP_aes_256_ctr();
    default: return NULL;
    }
}

// One-shot symmetric encrypt/decrypt of the buffered input.
static CK_RV aes_run(struct op *op, int enc, unsigned char **res, size_t *res_len) {
    struct attr *kv = get_attr(op->key, CKA_VALUE);
    if (!kv) return CKR_KEY_HANDLE_INVALID;
    const EVP_CIPHER *c = aes_cipher(op->mech, kv->len);
    if (!c) { LOG("unsupported cipher mechanism 0x%lx", op->mech); return CKR_MECHANISM_INVALID; }
    const unsigned char *iv = NULL, *aad = NULL; size_t ivlen = 0, aadlen = 0, tag = 16;
    if (op->mech == CKM_AES_GCM) {
        CK_GCM_PARAMS *g = (CK_GCM_PARAMS *)op->param;
        if (!g) return CKR_MECHANISM_PARAM_INVALID;
        iv = g->pIv; ivlen = g->ulIvLen; aad = g->pAAD; aadlen = g->ulAADLen; tag = g->ulTagBits / 8;
    } else if (op->mech == CKM_AES_CTR) {
        CK_AES_CTR_PARAMS *p = (CK_AES_CTR_PARAMS *)op->param;
        iv = p->cb; ivlen = 16;
    } else if (op->mech != CKM_AES_ECB) {
        iv = op->param; ivlen = op->param_len;
    }
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    unsigned char *out = malloc(op->len + 64);
    int n = 0, f = 0, ok = EVP_CipherInit_ex(ctx, c, NULL, NULL, NULL, enc);
    const unsigned char *in = op->buf; size_t inlen = op->len;
    if (op->mech == CKM_AES_GCM) {
        ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)ivlen, NULL);
        if (!enc) {
            if (inlen < tag) ok = 0;
            else { inlen -= tag; ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)tag, (void *)(in + inlen)); }
        }
    }
    ok = ok && EVP_CipherInit_ex(ctx, NULL, NULL, kv->val, iv, enc);
    EVP_CIPHER_CTX_set_padding(ctx, op->mech == CKM_AES_CBC_PAD);
    if (aadlen) ok = ok && EVP_CipherUpdate(ctx, NULL, &n, aad, (int)aadlen);
    ok = ok && EVP_CipherUpdate(ctx, out, &n, in, (int)inlen);
    ok = ok && EVP_CipherFinal_ex(ctx, out + n, &f);
    size_t total = (size_t)n + f;
    if (ok && enc && op->mech == CKM_AES_GCM) {
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, (int)tag, out + total);
        total += tag;
    }
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) { free(out); return enc ? CKR_FUNCTION_FAILED : CKR_ENCRYPTED_DATA_INVALID; }
    *res = out; *res_len = total;
    return CKR_OK;
}

static EVP_PKEY *load_private(struct obj *key) {
    struct attr *a = get_attr(key, CKA_VALUE);
    if (!a) return NULL;
    const unsigned char *p = a->val;
    return d2i_AutoPrivateKey(NULL, &p, (long)a->len);
}
static EVP_PKEY *load_public(struct obj *key) {
    struct attr *a = get_attr(key, CKA_VENDOR_DEFINED | 1);  // SubjectPublicKeyInfo DER we stash
    if (!a) a = get_attr(key, CKA_PUBLIC_KEY_INFO);
    if (!a) return NULL;
    const unsigned char *p = a->val;
    return d2i_PUBKEY(NULL, &p, (long)a->len);
}

// ECDSA signatures in PKCS#11 are raw r||s, OpenSSL produces DER.
static int ecdsa_der_to_raw(const unsigned char *der, size_t len, unsigned char *out, size_t half) {
    ECDSA_SIG *s = d2i_ECDSA_SIG(NULL, &der, (long)len);
    if (!s) return 0;
    const BIGNUM *r, *ss; ECDSA_SIG_get0(s, &r, &ss);
    BN_bn2binpad(r, out, (int)half); BN_bn2binpad(ss, out + half, (int)half);
    ECDSA_SIG_free(s);
    return 1;
}
static unsigned char *ecdsa_raw_to_der(const unsigned char *raw, size_t len, size_t *der_len) {
    ECDSA_SIG *s = ECDSA_SIG_new();
    ECDSA_SIG_set0(s, BN_bin2bn(raw, (int)len / 2, NULL), BN_bin2bn(raw + len / 2, (int)len / 2, NULL));
    unsigned char *der = NULL;
    int n = i2d_ECDSA_SIG(s, &der);
    ECDSA_SIG_free(s);
    *der_len = n > 0 ? (size_t)n : 0;
    return der;
}

static int is_hmac(CK_MECHANISM_TYPE m) {
    return m == CKM_SHA_1_HMAC || m == CKM_SHA224_HMAC || m == CKM_SHA256_HMAC || m == CKM_SHA384_HMAC || m == CKM_SHA512_HMAC;
}
static int is_ecdsa(CK_MECHANISM_TYPE m) {
    return m == CKM_ECDSA || m == CKM_ECDSA_SHA1 || m == CKM_ECDSA_SHA224 || m == CKM_ECDSA_SHA256 || m == CKM_ECDSA_SHA384 || m == CKM_ECDSA_SHA512;
}

static CK_RV sign_run(struct op *op, unsigned char **res, size_t *res_len) {
    CK_MECHANISM_TYPE m = op->mech;
    if (is_hmac(m)) {
        struct attr *kv = get_attr(op->key, CKA_VALUE);
        unsigned char *out = malloc(EVP_MAX_MD_SIZE); unsigned int n = 0;
        if (!kv || !HMAC(md_for(m), kv->val, (int)kv->len, op->buf, op->len, out, &n)) { free(out); return CKR_FUNCTION_FAILED; }
        *res = out; *res_len = n;
        return CKR_OK;
    }
    EVP_PKEY *pk = load_private(op->key);
    if (!pk) return CKR_KEY_HANDLE_INVALID;
    const EVP_MD *md = md_for(m);
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new(pk, NULL);
    size_t siglen = 0; unsigned char *sig = NULL; int ok = 1;
    unsigned char digest[EVP_MAX_MD_SIZE]; unsigned int dlen = 0;
    const unsigned char *tbs = op->buf; size_t tbslen = op->len;
    if (md) { EVP_Digest(op->buf, op->len, digest, &dlen, md, NULL); tbs = digest; tbslen = dlen; }
    ok = EVP_PKEY_sign_init(pctx) > 0;
    if (ok && EVP_PKEY_base_id(pk) == EVP_PKEY_RSA) {
        int pss = m == CKM_RSA_PKCS_PSS || m == CKM_SHA1_RSA_PKCS_PSS || m == CKM_SHA256_RSA_PKCS_PSS ||
                  m == CKM_SHA384_RSA_PKCS_PSS || m == CKM_SHA512_RSA_PKCS_PSS;
        EVP_PKEY_CTX_set_rsa_padding(pctx, pss ? RSA_PKCS1_PSS_PADDING : RSA_PKCS1_PADDING);
        if (md) EVP_PKEY_CTX_set_signature_md(pctx, md);
        if (pss && op->param) {
            CK_RSA_PKCS_PSS_PARAMS *pp = (CK_RSA_PKCS_PSS_PARAMS *)op->param;
            EVP_PKEY_CTX_set_signature_md(pctx, md_for(pp->hashAlg));
            EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, (int)pp->sLen);
        }
    }
    ok = ok && EVP_PKEY_sign(pctx, NULL, &siglen, tbs, tbslen) > 0;
    sig = malloc(siglen + 1);
    ok = ok && EVP_PKEY_sign(pctx, sig, &siglen, tbs, tbslen) > 0;
    if (ok && is_ecdsa(m)) {
        size_t half = (size_t)(EVP_PKEY_get_bits(pk) + 7) / 8;
        unsigned char *raw = malloc(half * 2);
        ok = ecdsa_der_to_raw(sig, siglen, raw, half);
        free(sig); sig = raw; siglen = half * 2;
    }
    EVP_PKEY_CTX_free(pctx); EVP_PKEY_free(pk);
    if (!ok) { free(sig); return CKR_FUNCTION_FAILED; }
    *res = sig; *res_len = siglen;
    return CKR_OK;
}

static CK_RV verify_run(struct op *op, const unsigned char *sig, size_t siglen) {
    CK_MECHANISM_TYPE m = op->mech;
    if (is_hmac(m)) {
        unsigned char *mac; size_t n;
        CK_RV rv = sign_run(op, &mac, &n);
        if (rv) return rv;
        int ok = n == siglen && !CRYPTO_memcmp(mac, sig, n);
        free(mac);
        return ok ? CKR_OK : CKR_SIGNATURE_INVALID;
    }
    EVP_PKEY *pk = load_public(op->key);
    if (!pk) return CKR_KEY_HANDLE_INVALID;
    const EVP_MD *md = md_for(m);
    unsigned char digest[EVP_MAX_MD_SIZE]; unsigned int dlen = 0;
    const unsigned char *tbs = op->buf; size_t tbslen = op->len;
    if (md) { EVP_Digest(op->buf, op->len, digest, &dlen, md, NULL); tbs = digest; tbslen = dlen; }
    unsigned char *der = NULL; size_t derlen = 0;
    if (is_ecdsa(m)) { der = ecdsa_raw_to_der(sig, siglen, &derlen); sig = der; siglen = derlen; }
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new(pk, NULL);
    int ok = EVP_PKEY_verify_init(pctx) > 0;
    if (ok && EVP_PKEY_base_id(pk) == EVP_PKEY_RSA && md) {
        EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING);
        EVP_PKEY_CTX_set_signature_md(pctx, md);
    }
    ok = ok && EVP_PKEY_verify(pctx, sig, siglen, tbs, tbslen) == 1;
    EVP_PKEY_CTX_free(pctx); EVP_PKEY_free(pk); OPENSSL_free(der);
    return ok ? CKR_OK : CKR_SIGNATURE_INVALID;
}

// ---------------------------------------------------------------- API

// Real devices get a device key pair at the factory. Mint one on first use so
// the device-token slot isn't empty (it can't authenticate to the cloud).
static void provision_device_token(void) {
    for (struct obj *o = objs; o; o = o->next)
        if (o->slot == 1 && get_ulong(o, CKA_CLASS, -1) == CKO_PRIVATE_KEY) return;
    EVP_PKEY *pk = EVP_EC_gen("prime256v1");
    if (!pk) return;
    static const unsigned char p256_oid[] = { 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
    unsigned char pt_buf[128]; size_t ptlen = 0;
    EVP_PKEY_get_octet_string_param(pk, OSSL_PKEY_PARAM_PUB_KEY, pt_buf, sizeof pt_buf, &ptlen);
    ASN1_OCTET_STRING *os = ASN1_OCTET_STRING_new();
    ASN1_OCTET_STRING_set(os, pt_buf, (int)ptlen);
    unsigned char *point = NULL; int point_len = i2d_ASN1_OCTET_STRING(os, &point);
    ASN1_OCTET_STRING_free(os);
    unsigned char *priv_der = NULL; int priv_len = i2d_PrivateKey(pk, &priv_der);
    unsigned char *spki = NULL; int spki_len = i2d_PUBKEY(pk, &spki);
    static const char label[] = "device-key";
    unsigned char id[] = { 0x01 };
    for (int pub = 0; pub < 2; pub++) {
        struct obj *o = new_obj(0);
        o->slot = 1;
        set_ulong(o, CKA_CLASS, pub ? CKO_PUBLIC_KEY : CKO_PRIVATE_KEY);
        set_ulong(o, CKA_KEY_TYPE, CKK_EC);
        set_bool(o, CKA_TOKEN, 1); set_bool(o, CKA_LOCAL, 1);
        set_attr(o, CKA_LABEL, label, sizeof label - 1);
        set_attr(o, CKA_ID, id, sizeof id);
        set_attr(o, CKA_EC_PARAMS, p256_oid, sizeof p256_oid);
        set_attr(o, CKA_EC_POINT, point, point_len);
        set_attr(o, CKA_PUBLIC_KEY_INFO, spki, spki_len);
        if (pub) { set_bool(o, CKA_VERIFY, 1); }
        else { set_bool(o, CKA_SIGN, 1); set_bool(o, CKA_SENSITIVE, 1); set_bool(o, CKA_EXTRACTABLE, 0); set_bool(o, CKA_PRIVATE, 1);
               set_attr(o, CKA_VALUE, priv_der, priv_len); }
    }
    OPENSSL_free(point); OPENSSL_free(priv_der); OPENSSL_free(spki); EVP_PKEY_free(pk);
    save();
    LOG("provisioned device-token EC P-256 key");
}

static CK_FUNCTION_LIST list;

CK_RV C_Initialize(CK_VOID_PTR args) {
    (void)args;
    LOCK;
    if (initialized) RET(CKR_CRYPTOKI_ALREADY_INITIALIZED);
    const char *p = getenv("RMEMU_TOKEN_DB");
    snprintf(db_path, sizeof db_path, "%s", p ? p : "/home/root/.local/share/rmemu/token.db");
    char dir[256]; snprintf(dir, sizeof dir, "%s", db_path);
    for (char *s = dir + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(dir, 0700); *s = '/'; }
    load();
    provision_device_token();
    initialized = 1;
    LOG("C_Initialize (db %s)", db_path);
    RET(CKR_OK);
}
CK_RV C_Finalize(CK_VOID_PTR r) {
    (void)r;
    LOCK; initialized = 0; RET(CKR_OK);
}
CK_RV C_GetInfo(CK_INFO_PTR i) {
    memset(i, ' ', sizeof *i);
    i->cryptokiVersion = (CK_VERSION){ 2, 40 };
    memcpy(i->manufacturerID, "rmemu", 5);
    i->flags = 0;
    memcpy(i->libraryDescription, "rmemu soft token", 16);
    i->libraryVersion = (CK_VERSION){ 1, 0 };
    return CKR_OK;
}
CK_RV C_GetFunctionList(CK_FUNCTION_LIST_PTR_PTR out) { *out = &list; return CKR_OK; }
// The device has a per-user token and a factory-provisioned device token.
static const char *const slot_labels[] = { "user-token", "device-token" };
#define NSLOTS 2

CK_RV C_GetSlotList(CK_BBOOL present, CK_SLOT_ID_PTR slots, CK_ULONG_PTR n) {
    (void)present;
    if (slots) {
        if (*n < NSLOTS) { *n = NSLOTS; return CKR_BUFFER_TOO_SMALL; }
        for (CK_ULONG i = 0; i < NSLOTS; i++) slots[i] = i;
    }
    *n = NSLOTS;
    return CKR_OK;
}
CK_RV C_GetSlotInfo(CK_SLOT_ID id, CK_SLOT_INFO_PTR i) {
    if (id >= NSLOTS) return CKR_SLOT_ID_INVALID;
    memset(i, ' ', sizeof *i);
    memcpy(i->slotDescription, "rmemu slot", 10);
    memcpy(i->manufacturerID, "rmemu", 5);
    i->flags = CKF_TOKEN_PRESENT;
    i->hardwareVersion = i->firmwareVersion = (CK_VERSION){ 1, 0 };
    return CKR_OK;
}
CK_RV C_GetTokenInfo(CK_SLOT_ID id, CK_TOKEN_INFO_PTR i) {
    if (id >= NSLOTS) return CKR_SLOT_ID_INVALID;
    memset(i, ' ', sizeof *i);
    memcpy(i->label, slot_labels[id], strlen(slot_labels[id]));
    memcpy(i->manufacturerID, "rmemu", 5);
    memcpy(i->model, "softtoken", 9);
    memcpy(i->serialNumber, id ? "0000000000000002" : "0000000000000001", 16);
    i->flags = CKF_RNG | CKF_TOKEN_INITIALIZED | CKF_USER_PIN_INITIALIZED;
    i->ulMaxSessionCount = i->ulMaxRwSessionCount = CK_EFFECTIVELY_INFINITE;
    i->ulSessionCount = i->ulRwSessionCount = CK_UNAVAILABLE_INFORMATION;
    i->ulMaxPinLen = 128; i->ulMinPinLen = 0;
    i->ulTotalPublicMemory = i->ulFreePublicMemory = i->ulTotalPrivateMemory = i->ulFreePrivateMemory = CK_UNAVAILABLE_INFORMATION;
    i->hardwareVersion = i->firmwareVersion = (CK_VERSION){ 1, 0 };
    memcpy(i->utcTime, "0000000000000000", 16);
    return CKR_OK;
}
static const CK_MECHANISM_TYPE mechs[] = {
    CKM_AES_KEY_GEN, CKM_AES_GCM, CKM_AES_CBC, CKM_AES_CBC_PAD, CKM_AES_ECB, CKM_AES_CTR,
    CKM_GENERIC_SECRET_KEY_GEN, CKM_SHA256_HMAC, CKM_SHA384_HMAC, CKM_SHA512_HMAC, CKM_SHA_1_HMAC,
    CKM_SHA256, CKM_SHA384, CKM_SHA512, CKM_SHA_1,
    CKM_EC_KEY_PAIR_GEN, CKM_ECDSA, CKM_ECDSA_SHA256, CKM_ECDSA_SHA384, CKM_ECDSA_SHA512,
    CKM_RSA_PKCS_KEY_PAIR_GEN, CKM_RSA_PKCS, CKM_SHA256_RSA_PKCS, CKM_RSA_PKCS_PSS, CKM_SHA256_RSA_PKCS_PSS,
};
CK_RV C_GetMechanismList(CK_SLOT_ID id, CK_MECHANISM_TYPE_PTR out, CK_ULONG_PTR n) {
    (void)id;
    CK_ULONG cnt = sizeof mechs / sizeof *mechs;
    if (out) { if (*n < cnt) { *n = cnt; return CKR_BUFFER_TOO_SMALL; } memcpy(out, mechs, sizeof mechs); }
    *n = cnt;
    return CKR_OK;
}
CK_RV C_GetMechanismInfo(CK_SLOT_ID id, CK_MECHANISM_TYPE t, CK_MECHANISM_INFO_PTR i) {
    (void)id;
    i->ulMinKeySize = 0; i->ulMaxKeySize = 8192;
    i->flags = CKF_HW | CKF_ENCRYPT | CKF_DECRYPT | CKF_SIGN | CKF_VERIFY | CKF_GENERATE | CKF_GENERATE_KEY_PAIR | CKF_DIGEST;
    if (t == CKM_EC_KEY_PAIR_GEN || t == CKM_ECDSA) i->flags |= CKF_EC_F_P | CKF_EC_NAMEDCURVE | CKF_EC_UNCOMPRESS;
    return CKR_OK;
}
CK_RV C_InitToken(CK_SLOT_ID id, CK_UTF8CHAR_PTR pin, CK_ULONG n, CK_UTF8CHAR_PTR label) {
    (void)id; (void)pin; (void)n; (void)label;
    LOG("C_InitToken");
    return CKR_OK;
}
CK_RV C_InitPIN(CK_SESSION_HANDLE s, CK_UTF8CHAR_PTR pin, CK_ULONG n) { (void)s; (void)pin; (void)n; return CKR_OK; }
CK_RV C_SetPIN(CK_SESSION_HANDLE s, CK_UTF8CHAR_PTR a, CK_ULONG an, CK_UTF8CHAR_PTR b, CK_ULONG bn) {
    (void)s; (void)a; (void)an; (void)b; (void)bn;
    return CKR_OK;
}
CK_RV C_OpenSession(CK_SLOT_ID id, CK_FLAGS flags, CK_VOID_PTR app, CK_NOTIFY notify, CK_SESSION_HANDLE_PTR out) {
    (void)app; (void)notify;
    if (id >= NSLOTS) return CKR_SLOT_ID_INVALID;
    LOCK;
    struct session *s = calloc(1, sizeof *s);
    s->h = next_session++; s->slot = id; s->flags = flags; s->next = sessions; sessions = s;
    *out = s->h;
    RET(CKR_OK);
}
static void close_session(struct session *s) {
    for (int i = 0; i < NOPS; i++) op_reset(&s->ops[i]);
    for (struct obj *o = objs, *n; o; o = n) { n = o->next; if (o->owner == s->h && !get_bool(o, CKA_TOKEN, 0)) free_obj(o); }
    for (struct session **p = &sessions; *p; p = &(*p)->next) if (*p == s) { *p = s->next; break; }
    free(s);
}
CK_RV C_CloseSession(CK_SESSION_HANDLE h) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    close_session(s);
    RET(CKR_OK);
}
CK_RV C_CloseAllSessions(CK_SLOT_ID id) {
    (void)id;
    LOCK;
    while (sessions) close_session(sessions);
    RET(CKR_OK);
}
CK_RV C_GetSessionInfo(CK_SESSION_HANDLE h, CK_SESSION_INFO_PTR i) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    i->slotID = s->slot; i->flags = s->flags; i->ulDeviceError = 0;
    int rw = s->flags & CKF_RW_SESSION;
    i->state = logged_in ? (rw ? CKS_RW_USER_FUNCTIONS : CKS_RO_USER_FUNCTIONS) : (rw ? CKS_RW_PUBLIC_SESSION : CKS_RO_PUBLIC_SESSION);
    RET(CKR_OK);
}
CK_RV C_Login(CK_SESSION_HANDLE h, CK_USER_TYPE t, CK_UTF8CHAR_PTR pin, CK_ULONG n) {
    (void)h; (void)t; (void)pin; (void)n;
    LOCK;
    if (logged_in) RET(CKR_USER_ALREADY_LOGGED_IN);
    logged_in = 1;
    RET(CKR_OK);
}
CK_RV C_Logout(CK_SESSION_HANDLE h) { (void)h; LOCK; logged_in = 0; RET(CKR_OK); }

CK_RV C_CreateObject(CK_SESSION_HANDLE h, CK_ATTRIBUTE_PTR t, CK_ULONG n, CK_OBJECT_HANDLE_PTR out) {
    LOCK;
    if (!get_session(h)) RET(CKR_SESSION_HANDLE_INVALID);
    struct obj *o = new_obj(h);
    apply_template(o, t, n);
    *out = o->h;
    if (get_bool(o, CKA_TOKEN, 0)) save();
    RET(CKR_OK);
}
CK_RV C_CopyObject(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE src, CK_ATTRIBUTE_PTR t, CK_ULONG n, CK_OBJECT_HANDLE_PTR out) {
    LOCK;
    struct obj *s = find_obj(src);
    if (!s) RET(CKR_OBJECT_HANDLE_INVALID);
    struct obj *o = new_obj(h);
    for (int i = 0; i < s->nattrs; i++) set_attr(o, s->attrs[i].type, s->attrs[i].val, s->attrs[i].len);
    apply_template(o, t, n);
    *out = o->h;
    if (get_bool(o, CKA_TOKEN, 0)) save();
    RET(CKR_OK);
}
CK_RV C_DestroyObject(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE oh) {
    (void)h;
    LOCK;
    struct obj *o = find_obj(oh);
    if (!o) RET(CKR_OBJECT_HANDLE_INVALID);
    int tok = get_bool(o, CKA_TOKEN, 0);
    free_obj(o);
    if (tok) save();
    RET(CKR_OK);
}
CK_RV C_GetObjectSize(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE oh, CK_ULONG_PTR n) {
    (void)h;
    LOCK;
    struct obj *o = find_obj(oh);
    if (!o) RET(CKR_OBJECT_HANDLE_INVALID);
    *n = 0;
    for (int i = 0; i < o->nattrs; i++) *n += o->attrs[i].len;
    RET(CKR_OK);
}
CK_RV C_GetAttributeValue(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE oh, CK_ATTRIBUTE_PTR t, CK_ULONG n) {
    (void)h;
    LOCK;
    struct obj *o = find_obj(oh);
    if (!o) RET(CKR_OBJECT_HANDLE_INVALID);
    CK_RV rv = CKR_OK;
    int sensitive = get_bool(o, CKA_SENSITIVE, 0) || !get_bool(o, CKA_EXTRACTABLE, 1);
    for (CK_ULONG i = 0; i < n; i++) {
        struct attr *a = get_attr(o, t[i].type);
        if (t[i].type == CKA_VALUE && sensitive && get_ulong(o, CKA_CLASS, 0) != CKO_DATA) {
            t[i].ulValueLen = CK_UNAVAILABLE_INFORMATION; rv = CKR_ATTRIBUTE_SENSITIVE; continue;
        }
        if (!a) { t[i].ulValueLen = CK_UNAVAILABLE_INFORMATION; rv = CKR_ATTRIBUTE_TYPE_INVALID; continue; }
        if (!t[i].pValue) { t[i].ulValueLen = a->len; continue; }
        if (t[i].ulValueLen < a->len) { t[i].ulValueLen = CK_UNAVAILABLE_INFORMATION; rv = CKR_BUFFER_TOO_SMALL; continue; }
        memcpy(t[i].pValue, a->val, a->len); t[i].ulValueLen = a->len;
    }
    RET(rv);
}
CK_RV C_SetAttributeValue(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE oh, CK_ATTRIBUTE_PTR t, CK_ULONG n) {
    (void)h;
    LOCK;
    struct obj *o = find_obj(oh);
    if (!o) RET(CKR_OBJECT_HANDLE_INVALID);
    apply_template(o, t, n);
    if (get_bool(o, CKA_TOKEN, 0)) save();
    RET(CKR_OK);
}
CK_RV C_FindObjectsInit(CK_SESSION_HANDLE h, CK_ATTRIBUTE_PTR t, CK_ULONG n) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    CK_RV rv = op_begin(s, OP_FIND, NULL, NULL);
    if (rv) RET(rv);
    struct op *op = &s->ops[OP_FIND];
    for (struct obj *o = objs; o; o = o->next) {
        if (o->slot != s->slot || !matches(o, t, n)) continue;
        op->found = realloc(op->found, sizeof *op->found * (op->nfound + 1));
        op->found[op->nfound++] = o->h;
    }
    RET(CKR_OK);
}
CK_RV C_FindObjects(CK_SESSION_HANDLE h, CK_OBJECT_HANDLE_PTR out, CK_ULONG max, CK_ULONG_PTR n) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    struct op *op = &s->ops[OP_FIND];
    if (!op->active) RET(CKR_OPERATION_NOT_INITIALIZED);
    *n = 0;
    while (op->pos < op->nfound && *n < max) out[(*n)++] = op->found[op->pos++];
    RET(CKR_OK);
}
CK_RV C_FindObjectsFinal(CK_SESSION_HANDLE h) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    op_reset(&s->ops[OP_FIND]);
    RET(CKR_OK);
}

// Generic init/update/final plumbing for the buffered operations.
static CK_RV init_op(CK_SESSION_HANDLE h, int kind, CK_MECHANISM_PTR m, CK_OBJECT_HANDLE kh) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    struct obj *k = NULL;
    if (kind != OP_DIGEST) { k = find_obj(kh); if (!k) RET(CKR_KEY_HANDLE_INVALID); }
    RET(op_begin(s, kind, m, k));
}
static CK_RV update_op(CK_SESSION_HANDLE h, int kind, CK_BYTE_PTR d, CK_ULONG n) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    if (!s->ops[kind].active) RET(CKR_OPERATION_NOT_INITIALIZED);
    op_feed(&s->ops[kind], d, n);
    RET(CKR_OK);
}
static CK_RV final_op(CK_SESSION_HANDLE h, int kind, CK_BYTE_PTR out, CK_ULONG_PTR out_len) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    struct op *op = &s->ops[kind];
    if (!op->active) RET(CKR_OPERATION_NOT_INITIALIZED);
    unsigned char *res = NULL; size_t n = 0; CK_RV rv;
    switch (kind) {
    case OP_ENC: rv = aes_run(op, 1, &res, &n); break;
    case OP_DEC: rv = aes_run(op, 0, &res, &n); break;
    case OP_SIGN: rv = sign_run(op, &res, &n); break;
    case OP_DIGEST: {
        res = malloc(EVP_MAX_MD_SIZE); unsigned int dn = 0;
        const EVP_MD *md = md_for(op->mech);
        rv = md && EVP_Digest(op->buf, op->len, res, &dn, md, NULL) ? CKR_OK : CKR_MECHANISM_INVALID;
        n = dn; break;
    }
    default: rv = CKR_FUNCTION_FAILED;
    }
    if (rv == CKR_OK) {
        rv = output(res, n, out, out_len);
        // A size query (NULL output, or too small) leaves the operation active.
        if (!out || rv == CKR_BUFFER_TOO_SMALL) { free(res); RET(rv); }
    }
    free(res);
    op_reset(op);
    RET(rv);
}
static CK_RV oneshot(CK_SESSION_HANDLE h, int kind, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR out, CK_ULONG_PTR out_len) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    struct op *op = &s->ops[kind];
    if (!op->active) RET(CKR_OPERATION_NOT_INITIALIZED);
    // Size queries call us again with the same input; don't double-buffer it.
    free(op->buf); op->buf = NULL; op->len = 0;
    op_feed(op, d, n);
    UNLOCK;
    return final_op(h, kind, out, out_len);
}

CK_RV C_EncryptInit(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_OBJECT_HANDLE k) { return init_op(h, OP_ENC, m, k); }
CK_RV C_Encrypt(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { return oneshot(h, OP_ENC, d, n, o, on); }
CK_RV C_EncryptUpdate(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { *on = 0; (void)o; return update_op(h, OP_ENC, d, n); }
CK_RV C_EncryptFinal(CK_SESSION_HANDLE h, CK_BYTE_PTR o, CK_ULONG_PTR on) { return final_op(h, OP_ENC, o, on); }
CK_RV C_DecryptInit(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_OBJECT_HANDLE k) { return init_op(h, OP_DEC, m, k); }
CK_RV C_Decrypt(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { return oneshot(h, OP_DEC, d, n, o, on); }
CK_RV C_DecryptUpdate(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { *on = 0; (void)o; return update_op(h, OP_DEC, d, n); }
CK_RV C_DecryptFinal(CK_SESSION_HANDLE h, CK_BYTE_PTR o, CK_ULONG_PTR on) { return final_op(h, OP_DEC, o, on); }
CK_RV C_DigestInit(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m) { return init_op(h, OP_DIGEST, m, 0); }
CK_RV C_Digest(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { return oneshot(h, OP_DIGEST, d, n, o, on); }
CK_RV C_DigestUpdate(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n) { return update_op(h, OP_DIGEST, d, n); }
CK_RV C_DigestFinal(CK_SESSION_HANDLE h, CK_BYTE_PTR o, CK_ULONG_PTR on) { return final_op(h, OP_DIGEST, o, on); }
CK_RV C_SignInit(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_OBJECT_HANDLE k) { return init_op(h, OP_SIGN, m, k); }
CK_RV C_Sign(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n, CK_BYTE_PTR o, CK_ULONG_PTR on) { return oneshot(h, OP_SIGN, d, n, o, on); }
CK_RV C_SignUpdate(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n) { return update_op(h, OP_SIGN, d, n); }
CK_RV C_SignFinal(CK_SESSION_HANDLE h, CK_BYTE_PTR o, CK_ULONG_PTR on) { return final_op(h, OP_SIGN, o, on); }
CK_RV C_VerifyInit(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_OBJECT_HANDLE k) { return init_op(h, OP_VERIFY, m, k); }
CK_RV C_VerifyUpdate(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG n) { return update_op(h, OP_VERIFY, d, n); }
static CK_RV verify_final(CK_SESSION_HANDLE h, CK_BYTE_PTR sig, CK_ULONG n) {
    LOCK;
    struct session *s = get_session(h);
    if (!s) RET(CKR_SESSION_HANDLE_INVALID);
    struct op *op = &s->ops[OP_VERIFY];
    if (!op->active) RET(CKR_OPERATION_NOT_INITIALIZED);
    CK_RV rv = verify_run(op, sig, n);
    op_reset(op);
    RET(rv);
}
CK_RV C_VerifyFinal(CK_SESSION_HANDLE h, CK_BYTE_PTR sig, CK_ULONG n) { return verify_final(h, sig, n); }
CK_RV C_Verify(CK_SESSION_HANDLE h, CK_BYTE_PTR d, CK_ULONG dn, CK_BYTE_PTR sig, CK_ULONG sn) {
    CK_RV rv = update_op(h, OP_VERIFY, d, dn);
    return rv ? rv : verify_final(h, sig, sn);
}

static void fill_key_defaults(struct obj *o, CK_OBJECT_CLASS cls, CK_KEY_TYPE kt, CK_MECHANISM_TYPE mech) {
    if (!get_attr(o, CKA_CLASS)) set_ulong(o, CKA_CLASS, cls);
    if (!get_attr(o, CKA_KEY_TYPE)) set_ulong(o, CKA_KEY_TYPE, kt);
    if (!get_attr(o, CKA_TOKEN)) set_bool(o, CKA_TOKEN, 0);
    if (!get_attr(o, CKA_LOCAL)) set_bool(o, CKA_LOCAL, 1);
    set_ulong(o, CKA_KEY_GEN_MECHANISM, mech);
}

CK_RV C_GenerateKey(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_ATTRIBUTE_PTR t, CK_ULONG n, CK_OBJECT_HANDLE_PTR out) {
    LOCK;
    if (!get_session(h)) RET(CKR_SESSION_HANDLE_INVALID);
    if (m->mechanism != CKM_AES_KEY_GEN && m->mechanism != CKM_GENERIC_SECRET_KEY_GEN) {
        LOG("C_GenerateKey: unsupported mechanism 0x%lx", m->mechanism);
        RET(CKR_MECHANISM_INVALID);
    }
    struct obj *o = new_obj(h);
    apply_template(o, t, n);
    CK_ULONG len = get_ulong(o, CKA_VALUE_LEN, 32);
    unsigned char *v = malloc(len);
    RAND_bytes(v, (int)len);
    set_attr(o, CKA_VALUE, v, len); free(v);
    fill_key_defaults(o, CKO_SECRET_KEY, m->mechanism == CKM_AES_KEY_GEN ? CKK_AES : CKK_GENERIC_SECRET, m->mechanism);
    *out = o->h;
    LOG("C_GenerateKey %s len=%lu -> %lu", m->mechanism == CKM_AES_KEY_GEN ? "AES" : "generic", len, o->h);
    if (get_bool(o, CKA_TOKEN, 0)) save();
    RET(CKR_OK);
}

// Map a DER-encoded curve OID (CKA_EC_PARAMS) to an OpenSSL group name.
static const char *curve_name(struct attr *params) {
    if (!params) return "prime256v1";
    const unsigned char *p = params->val;
    ASN1_OBJECT *oid = d2i_ASN1_OBJECT(NULL, &p, (long)params->len);
    if (!oid) return NULL;
    const char *name = OBJ_nid2sn(OBJ_obj2nid(oid));
    ASN1_OBJECT_free(oid);
    return name;
}

CK_RV C_GenerateKeyPair(CK_SESSION_HANDLE h, CK_MECHANISM_PTR m, CK_ATTRIBUTE_PTR pt, CK_ULONG pn, CK_ATTRIBUTE_PTR st,
                        CK_ULONG sn, CK_OBJECT_HANDLE_PTR pub_out, CK_OBJECT_HANDLE_PTR priv_out) {
    LOCK;
    if (!get_session(h)) RET(CKR_SESSION_HANDLE_INVALID);
    struct obj *pub = new_obj(h), *priv = new_obj(h);
    apply_template(pub, pt, pn); apply_template(priv, st, sn);
    EVP_PKEY *pk = NULL;
    if (m->mechanism == CKM_EC_KEY_PAIR_GEN) {
        const char *curve = curve_name(get_attr(pub, CKA_EC_PARAMS));
        if (!curve) { free_obj(pub); free_obj(priv); RET(CKR_DOMAIN_PARAMS_INVALID); }
        pk = EVP_EC_gen(curve);
        if (pk) {
            // CKA_EC_POINT is a DER OCTET STRING around the uncompressed point.
            unsigned char pt_buf[256]; size_t ptlen = 0;
            EVP_PKEY_get_octet_string_param(pk, OSSL_PKEY_PARAM_PUB_KEY, pt_buf, sizeof pt_buf, &ptlen);
            ASN1_OCTET_STRING *os = ASN1_OCTET_STRING_new();
            ASN1_OCTET_STRING_set(os, pt_buf, (int)ptlen);
            unsigned char *der = NULL; int dl = i2d_ASN1_OCTET_STRING(os, &der);
            set_attr(pub, CKA_EC_POINT, der, dl);
            OPENSSL_free(der); ASN1_OCTET_STRING_free(os);
            struct attr *ep = get_attr(pub, CKA_EC_PARAMS);
            if (ep) set_attr(priv, CKA_EC_PARAMS, ep->val, ep->len);
            fill_key_defaults(pub, CKO_PUBLIC_KEY, CKK_EC, m->mechanism);
            fill_key_defaults(priv, CKO_PRIVATE_KEY, CKK_EC, m->mechanism);
        }
    } else if (m->mechanism == CKM_RSA_PKCS_KEY_PAIR_GEN) {
        pk = EVP_RSA_gen((unsigned)get_ulong(pub, CKA_MODULUS_BITS, 2048));
        if (pk) {
            BIGNUM *nn = NULL, *e = NULL;
            EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_N, &nn);
            EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_E, &e);
            unsigned char b[1024]; int l;
            l = BN_bn2bin(nn, b); set_attr(pub, CKA_MODULUS, b, l); set_attr(priv, CKA_MODULUS, b, l);
            l = BN_bn2bin(e, b); set_attr(pub, CKA_PUBLIC_EXPONENT, b, l); set_attr(priv, CKA_PUBLIC_EXPONENT, b, l);
            BN_free(nn); BN_free(e);
            fill_key_defaults(pub, CKO_PUBLIC_KEY, CKK_RSA, m->mechanism);
            fill_key_defaults(priv, CKO_PRIVATE_KEY, CKK_RSA, m->mechanism);
        }
    } else {
        LOG("C_GenerateKeyPair: unsupported mechanism 0x%lx", m->mechanism);
        free_obj(pub); free_obj(priv);
        RET(CKR_MECHANISM_INVALID);
    }
    if (!pk) { free_obj(pub); free_obj(priv); RET(CKR_FUNCTION_FAILED); }
    unsigned char *der = NULL; int dl = i2d_PrivateKey(pk, &der);
    set_attr(priv, CKA_VALUE, der, dl); OPENSSL_free(der);
    der = NULL; dl = i2d_PUBKEY(pk, &der);
    set_attr(pub, CKA_PUBLIC_KEY_INFO, der, dl); set_attr(priv, CKA_PUBLIC_KEY_INFO, der, dl); OPENSSL_free(der);
    EVP_PKEY_free(pk);
    *pub_out = pub->h; *priv_out = priv->h;
    LOG("C_GenerateKeyPair %s -> pub %lu priv %lu", m->mechanism == CKM_EC_KEY_PAIR_GEN ? "EC" : "RSA", pub->h, priv->h);
    if (get_bool(pub, CKA_TOKEN, 0) || get_bool(priv, CKA_TOKEN, 0)) save();
    RET(CKR_OK);
}

CK_RV C_SeedRandom(CK_SESSION_HANDLE h, CK_BYTE_PTR s, CK_ULONG n) { (void)h; RAND_add(s, (int)n, (double)n); return CKR_OK; }
CK_RV C_GenerateRandom(CK_SESSION_HANDLE h, CK_BYTE_PTR out, CK_ULONG n) { (void)h; return RAND_bytes(out, (int)n) ? CKR_OK : CKR_FUNCTION_FAILED; }

#define STUB(name) static CK_RV stub_##name(void) { LOG(#name " (unimplemented)"); return CKR_FUNCTION_NOT_SUPPORTED; }
#define STUBS(X) X(C_GetOperationState) X(C_SetOperationState) X(C_DigestKey) X(C_SignRecoverInit) X(C_SignRecover) \
    X(C_VerifyRecoverInit) X(C_VerifyRecover) X(C_DigestEncryptUpdate) X(C_DecryptDigestUpdate) X(C_SignEncryptUpdate) \
    X(C_DecryptVerifyUpdate) X(C_WrapKey) X(C_UnwrapKey) X(C_DeriveKey) X(C_GetFunctionStatus) X(C_CancelFunction) \
    X(C_WaitForSlotEvent)
STUBS(STUB)

#define REAL_FUNCS(X) \
    X(C_Initialize) X(C_Finalize) X(C_GetInfo) X(C_GetFunctionList) X(C_GetSlotList) X(C_GetSlotInfo) \
    X(C_GetTokenInfo) X(C_GetMechanismList) X(C_GetMechanismInfo) X(C_InitToken) X(C_InitPIN) X(C_SetPIN) \
    X(C_OpenSession) X(C_CloseSession) X(C_CloseAllSessions) X(C_GetSessionInfo) X(C_Login) X(C_Logout) \
    X(C_CreateObject) X(C_CopyObject) X(C_DestroyObject) X(C_GetObjectSize) X(C_GetAttributeValue) \
    X(C_SetAttributeValue) X(C_FindObjectsInit) X(C_FindObjects) X(C_FindObjectsFinal) X(C_EncryptInit) \
    X(C_Encrypt) X(C_EncryptUpdate) X(C_EncryptFinal) X(C_DecryptInit) X(C_Decrypt) X(C_DecryptUpdate) \
    X(C_DecryptFinal) X(C_DigestInit) X(C_Digest) X(C_DigestUpdate) X(C_DigestFinal) X(C_SignInit) X(C_Sign) \
    X(C_SignUpdate) X(C_SignFinal) X(C_VerifyInit) X(C_Verify) X(C_VerifyUpdate) X(C_VerifyFinal) \
    X(C_GenerateKey) X(C_GenerateKeyPair) X(C_SeedRandom) X(C_GenerateRandom)

static CK_FUNCTION_LIST list = {
    .version = { 2, 40 },
#define SLOT_REAL(name) .name = name,
#define SLOT_STUB(name) .name = (void *)stub_##name,
    REAL_FUNCS(SLOT_REAL)
    STUBS(SLOT_STUB)
};
