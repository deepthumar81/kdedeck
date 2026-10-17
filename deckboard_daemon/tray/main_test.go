package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWaitForReadyURLRetriesUntilHealthEndpointIsAvailable(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests++
		if requests < 2 {
			response.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if err := waitForReadyURL(server.URL, time.Second); err != nil {
		t.Fatalf("waitForReadyURL() error = %v", err)
	}
	if requests < 2 {
		t.Fatalf("waitForReadyURL() made %d request(s), want a retry", requests)
	}
}

func TestWaitForReadyURLTimesOut(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()

	if err := waitForReadyURL(server.URL, 20*time.Millisecond); err == nil {
		t.Fatal("waitForReadyURL() error = nil, want timeout")
	}
}
