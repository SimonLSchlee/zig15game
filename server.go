package main

import (
    "log"
    "net/http"
)

func main() {
    http.HandleFunc(
        "/",
        func(w http.ResponseWriter, r *http.Request) {
            w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
            w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
            http.ServeFile(w, r, "zig-out/web/"+r.URL.Path[1:])
        })

    log.Fatal(http.ListenAndServe(":8083", nil))
}
