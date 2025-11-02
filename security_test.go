package main

import (
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestGenerateSecurePassword(t *testing.T) {
	tests := []struct {
		name   string
		length int
		want   int
	}{
		{"default length", 32, 32},
		{"custom length", 16, 16},
		{"zero defaults to 32", 0, 32},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			password, err := GenerateSecurePassword(tt.length)
			if err != nil {
				t.Errorf("GenerateSecurePassword() error = %v", err)
				return
			}
			if len(password) != tt.want {
				t.Errorf("GenerateSecurePassword() length = %d, want %d", len(password), tt.want)
			}
			// Verify password contains only allowed characters
			for _, ch := range password {
				if !strings.ContainsRune(passwordChars, ch) {
					t.Errorf("Password contains invalid character: %c", ch)
				}
			}
		})
	}
}

func TestHashPasswordForCloudInit(t *testing.T) {
	password := "testpassword123"
	hashed, err := HashPasswordForCloudInit(password)
	if err != nil {
		t.Fatalf("HashPasswordForCloudInit() error = %v", err)
	}

	// Verify it's a valid bcrypt hash
	if !strings.HasPrefix(hashed, "$2") {
		t.Errorf("Hash doesn't look like bcrypt: %s", hashed)
	}

	// Verify bcrypt can verify the hash
	err = bcrypt.CompareHashAndPassword([]byte(hashed), []byte(password))
	if err != nil {
		t.Errorf("Bcrypt verification failed: %v", err)
	}
}

func TestGenerateCloudInitUserData_Linux(t *testing.T) {
	shell := "bash"
	username := "testuser"
	password := "testpassword123"

	userdata, err := GenerateCloudInitUserData(shell, username, password)
	if err != nil {
		t.Fatalf("GenerateCloudInitUserData() error = %v", err)
	}

	// Verify Linux-specific cloud-init features
	tests := []struct {
		name    string
		want    string
		wantNot string
	}{
		{"has cloud-config header", "#cloud-config", ""},
		{"has username", username, ""},
		{"has sudo config", "sudo: ALL=(ALL) NOPASSWD:ALL", ""},
		{"has bash shell", "shell: /bin/bash", ""},
		{"has ssh_pwauth", "ssh_pwauth: true", ""},
		{"has chpasswd config", "chpasswd:", ""},
		{"does NOT have plaintext password", "", password},
		{"does NOT have Administrators group", "", "Administrators"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.want != "" && !strings.Contains(userdata, tt.want) {
				t.Errorf("Linux cloud-init missing expected content: %q", tt.want)
			}
			if tt.wantNot != "" && strings.Contains(userdata, tt.wantNot) {
				t.Errorf("Linux cloud-init contains unexpected content: %q", tt.wantNot)
			}
		})
	}

	// Verify password is bcrypt-hashed
	if strings.Contains(userdata, password) {
		t.Error("Linux cloud-init contains plaintext password (should be bcrypt-hashed)")
	}
	if !strings.Contains(userdata, "passwd: $2") {
		t.Error("Linux cloud-init doesn't contain bcrypt hash")
	}
}

func TestGenerateCloudInitUserData_Windows(t *testing.T) {
	shell := "pwsh"
	username := "testuser"
	password := "testpassword123"

	userdata, err := GenerateCloudInitUserData(shell, username, password)
	if err != nil {
		t.Fatalf("GenerateCloudInitUserData() error = %v", err)
	}

	// Verify Windows-specific cloud-init features
	tests := []struct {
		name    string
		want    string
		wantNot string
	}{
		{"has cloud-config header", "#cloud-config", ""},
		{"has username", username, ""},
		{"has plaintext password", password, ""},
		{"has Administrators group", "groups: Administrators", ""},
		{"does NOT have sudo config", "", "sudo:"},
		{"does NOT have bash shell", "", "/bin/bash"},
		{"does NOT have ssh_pwauth", "", "ssh_pwauth"},
		{"does NOT have chpasswd", "", "chpasswd:"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.want != "" && !strings.Contains(userdata, tt.want) {
				t.Errorf("Windows cloud-init missing expected content: %q", tt.want)
			}
			if tt.wantNot != "" && strings.Contains(userdata, tt.wantNot) {
				t.Errorf("Windows cloud-init contains unexpected content: %q", tt.wantNot)
			}
		})
	}

	// Verify password is plaintext (NOT bcrypt-hashed)
	if strings.Contains(userdata, "$2a$") || strings.Contains(userdata, "$2b$") {
		t.Error("Windows cloud-init contains bcrypt hash (should be plaintext)")
	}
}

func TestGenerateCloudInitUserData_InvalidShell(t *testing.T) {
	shell := "invalid"
	username := "testuser"
	password := "testpassword123"

	_, err := GenerateCloudInitUserData(shell, username, password)
	if err == nil {
		t.Error("GenerateCloudInitUserData() expected error for invalid shell, got nil")
	}

	expectedError := "unsupported shell"
	if !strings.Contains(err.Error(), expectedError) {
		t.Errorf("Error message = %q, want to contain %q", err.Error(), expectedError)
	}
}

func TestGenerateCloudInitUserData_BothOS(t *testing.T) {
	username := "testuser"
	password := "testpassword123"

	// Generate for both OS
	linuxUserdata, err := GenerateCloudInitUserData("bash", username, password)
	if err != nil {
		t.Fatalf("Linux cloud-init generation failed: %v", err)
	}

	windowsUserdata, err := GenerateCloudInitUserData("pwsh", username, password)
	if err != nil {
		t.Fatalf("Windows cloud-init generation failed: %v", err)
	}

	// Verify both have cloud-config header
	if !strings.HasPrefix(linuxUserdata, "#cloud-config") {
		t.Error("Linux cloud-init missing #cloud-config header")
	}
	if !strings.HasPrefix(windowsUserdata, "#cloud-config") {
		t.Error("Windows cloud-init missing #cloud-config header")
	}

	// Verify both have username
	if !strings.Contains(linuxUserdata, username) {
		t.Error("Linux cloud-init missing username")
	}
	if !strings.Contains(windowsUserdata, username) {
		t.Error("Windows cloud-init missing username")
	}

	// Verify they are different (Linux has more config)
	if len(linuxUserdata) <= len(windowsUserdata) {
		t.Error("Expected Linux cloud-init to be longer than Windows (has more config)")
	}
}
