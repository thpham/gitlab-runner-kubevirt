package main

import (
	"crypto/rand"
	"fmt"
	"math/big"

	"golang.org/x/crypto/bcrypt"
)

const (
	passwordLength = 32
	passwordChars  = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
)

// GenerateSecurePassword generates a cryptographically secure random password
func GenerateSecurePassword(length int) (string, error) {
	if length <= 0 {
		length = passwordLength
	}

	password := make([]byte, length)
	charsLen := big.NewInt(int64(len(passwordChars)))

	for i := 0; i < length; i++ {
		num, err := rand.Int(rand.Reader, charsLen)
		if err != nil {
			return "", fmt.Errorf("failed to generate random number: %w", err)
		}
		password[i] = passwordChars[num.Int64()]
	}

	return string(password), nil
}

// HashPasswordForCloudInit hashes a password using bcrypt for cloud-init
func HashPasswordForCloudInit(password string) (string, error) {
	hashedBytes, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("failed to hash password: %w", err)
	}
	return string(hashedBytes), nil
}

// GenerateCloudInitUserData creates cloud-init user-data for Linux or Windows VMs
// based on the shell parameter (bash = Linux, pwsh = Windows)
func GenerateCloudInitUserData(shell, username, password string) (string, error) {
	switch shell {
	case "bash":
		return generateLinuxCloudInit(username, password)
	case "pwsh":
		return generateWindowsCloudInit(username, password)
	default:
		return "", fmt.Errorf("unsupported shell: %s (expected 'bash' or 'pwsh')", shell)
	}
}

// generateLinuxCloudInit creates cloud-init user-data for Linux VMs with bcrypt-hashed passwords
func generateLinuxCloudInit(username, password string) (string, error) {
	hashedPassword, err := HashPasswordForCloudInit(password)
	if err != nil {
		return "", err
	}

	userData := fmt.Sprintf(`#cloud-config
users:
  - name: %s
    lock_passwd: false
    passwd: %s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false
`, username, hashedPassword)

	return userData, nil
}

// generateWindowsCloudInit creates cloud-init user-data for Windows VMs with plaintext passwords
// Windows uses Cloudbase-Init which follows industry standard of plaintext passwords
// see: https://cloudbase-init.readthedocs.io/en/latest/userdata.html#cloud-config
func generateWindowsCloudInit(username, password string) (string, error) {
	userData := fmt.Sprintf(`#cloud-config
users:
  - name: %s
    passwd: %s
    groups: Administrators
`, username, password)

	return userData, nil
}
