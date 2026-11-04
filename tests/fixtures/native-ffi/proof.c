#include <zlib.h>
#include "proof.h"
int answer(void) { return zlibVersion()[0] ? 42 : 0; }
