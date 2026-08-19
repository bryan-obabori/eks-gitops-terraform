package main

import (
	"log"
	"net/http"
)

func homePage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "static/home.html")
}

func pipelinePage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "static/pipeline.html")
}

func platformPage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "static/platform.html")
}

func deploymentPage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "static/deployment.html")
}

func aboutPage(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "static/about.html")
}

func main() {
	http.HandleFunc("/home", homePage)
	http.HandleFunc("/pipeline", pipelinePage)
	http.HandleFunc("/platform", platformPage)
	http.HandleFunc("/deployment", deploymentPage)
	http.HandleFunc("/about", aboutPage)
	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("static"))))

	err := http.ListenAndServe("0.0.0.0:8080", nil)
	if err != nil {
		log.Fatal(err)
	}
}
