#include <stdint.h>

int _start() {
	unsigned int a = 10;
	unsigned int b = 10;
	if (a <= b) {
		b = 20;
	}

	return b;
}
