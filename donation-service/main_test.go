package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLiveness(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/health/live", nil)
	response := httptest.NewRecorder()
	(&App{}).LiveHandler(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.Code)
	}
}

func TestDonationRejectsInvalidPayload(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/donations", strings.NewReader(`{"ngo_id":1,"amount":0,"donor_name":"Ana"}`))
	response := httptest.NewRecorder()
	(&App{}).DonationHandler(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", response.Code)
	}
}

func TestDonationRejectsUnknownFields(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/donations", strings.NewReader(`{"ngo_id":1,"amount":10,"donor_name":"Ana","admin":true}`))
	response := httptest.NewRecorder()
	(&App{}).DonationHandler(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", response.Code)
	}
}
