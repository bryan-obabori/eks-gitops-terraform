package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPages(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		handler http.HandlerFunc
	}{
		{name: "home", path: "/home", handler: homePage},
		{name: "pipeline", path: "/pipeline", handler: pipelinePage},
		{name: "platform", path: "/platform", handler: platformPage},
		{name: "deployment", path: "/deployment", handler: deploymentPage},
		{name: "about", path: "/about", handler: aboutPage},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, tt.path, nil)
			if err != nil {
				t.Fatal(err)
			}

			rr := httptest.NewRecorder()
			tt.handler.ServeHTTP(rr, req)

			if rr.Code != http.StatusOK {
				t.Fatalf("handler returned status %d, want %d", rr.Code, http.StatusOK)
			}

			if got := rr.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
				t.Fatalf("handler returned content type %q, want text/html; charset=utf-8", got)
			}
		})
	}
}
