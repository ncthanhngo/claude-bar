//go:build !windows

package usecase

// NewPlatformService is the composition root for this OS.
func NewPlatformService() *Service { return NewMacOSService() }
