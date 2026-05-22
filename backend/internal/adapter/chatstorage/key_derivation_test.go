package chatstorage

import (
	"bytes"
	"crypto/rand"
	"testing"
)

func TestDeriveKeys_Deterministic(t *testing.T) {
	master := bytes.Repeat([]byte{0xAB}, MasterKeySize)
	db1, at1 := DeriveKeys(master)
	db2, at2 := DeriveKeys(master)
	if !bytes.Equal(db1, db2) {
		t.Fatal("dbKey not deterministic")
	}
	if !bytes.Equal(at1, at2) {
		t.Fatal("attachKey not deterministic")
	}
}

func TestDeriveKeys_Independent(t *testing.T) {
	master := bytes.Repeat([]byte{0xCD}, MasterKeySize)
	db, at := DeriveKeys(master)
	if bytes.Equal(db, at) {
		t.Fatal("dbKey == attachKey — HKDF chain broken")
	}
	if len(db) != 32 || len(at) != 32 {
		t.Fatalf("key sizes wrong: %d / %d", len(db), len(at))
	}
}

func TestDeriveKeys_DifferentMastersDifferentKeys(t *testing.T) {
	m1 := make([]byte, MasterKeySize)
	m2 := make([]byte, MasterKeySize)
	_, _ = rand.Read(m1)
	_, _ = rand.Read(m2)
	db1, _ := DeriveKeys(m1)
	db2, _ := DeriveKeys(m2)
	if bytes.Equal(db1, db2) {
		t.Fatal("different masters yielded same dbKey")
	}
}
