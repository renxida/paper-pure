// fakeaccess stands in for Cloudflare Access in the local proof: it lets a
// request through only with the right service-token headers, like an Access
// app with one Service Auth policy per token. Test helper, never deployed.
//
//	fakeaccess -id ID -secret SECRET [-token ID2:SECRET2 ...]
package main

import (
	"flag"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

type tokens map[string]string // id -> secret

func (t tokens) String() string { return "" }
func (t tokens) Set(v string) error {
	id, secret, _ := strings.Cut(v, ":")
	t[id] = secret
	return nil
}

func main() {
	listen := flag.String("listen", "127.0.0.1:3091", "listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:3080", "origin (ppd)")
	id := flag.String("id", "", "CF-Access-Client-Id to accept")
	secret := flag.String("secret", "", "CF-Access-Client-Secret to accept")
	more := tokens{}
	flag.Var(more, "token", "another ID:SECRET to accept (repeatable)")
	flag.Parse()
	u, err := url.Parse(*upstream)
	if err != nil || *id == "" || *secret == "" {
		log.Fatal("need -upstream, -id and -secret")
	}
	more[*id] = *secret
	rp := httputil.NewSingleHostReverseProxy(u)
	log.Fatal(http.ListenAndServe(*listen, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		want, known := more[r.Header.Get("CF-Access-Client-Id")]
		if !known || want == "" || r.Header.Get("CF-Access-Client-Secret") != want {
			log.Printf("access: refused %s %s", r.Method, r.URL.Path)
			http.Error(w, "Forbidden (fake Cloudflare Access)", http.StatusForbidden)
			return
		}
		r.Header.Del("CF-Access-Client-Secret")
		rp.ServeHTTP(w, r)
	})))
}
