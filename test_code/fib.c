#include <stdint.h>

uint64_t fib(uint64_t n);


int _start() {
	uint64_t a = 38;
	uint64_t b = fib(a);
	return b;
}

uint64_t fib(uint64_t n) {
	if (n <= 1) {
		return n;
	}

	return fib(n - 1) + fib(n - 2);
}

