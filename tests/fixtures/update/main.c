/* SPDX-License-Identifier: MIT */
#include <stdio.h>
#include <zlib.h>

int main(void) {
  printf("zlib %s\n", zlibVersion());
  return 0;
}
