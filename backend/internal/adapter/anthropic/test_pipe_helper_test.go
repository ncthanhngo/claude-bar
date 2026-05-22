package anthropic

import "io"

// newPipe returns a writable pipe whose read end is bufio-friendly. Used by
// streaming tests to drive an io.Reader from goroutine-side writes.
func newPipe() (*io.PipeReader, *io.PipeWriter) {
	return io.Pipe()
}
