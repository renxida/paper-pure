// fakeaccess stands in for Cloudflare Access in the local proof: it lets a
// request through only with the right service-token headers, like an Access
// app with a Service Auth policy. Test helper, never deployed.
package main

import (
	"flag"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:3091", "listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:3080", "origin (ppd)")
	id := flag.String("id", "", "CF-Access-Client-Id to accept")
	secret := flag.String("secret", "", "CF-Access-Client-Secret to accept")
	flag.Parse()
	u, err := url.Parse(*upstream)
	if err != nil || *id == "" || *secret == "" {
		log.Fatal("need -upstream, -id and -secret")
	}
	rp := httputil.NewSingleHostReverseProxy(u)
	log.Fatal(http.ListenAndServe(*listen, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("CF-Access-Client-Id") != *id || r.Header.Get("CF-Access-Client-Secret") != *secret {
			log.Printf("access: refused %s %s", r.Method, r.URL.Path)
			http.Error(w, "Forbidden (fake Cloudflare Access)", http.StatusForbidden)
			return
		}
		r.Header.Del("CF-Access-Client-Secret")
		rp.ServeHTTP(w, r)
	})))
}
