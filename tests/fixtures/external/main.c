/* SPDX-License-Identifier: MIT */
#include <ini.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>

static int handler(void *user, const char *section, const char *name,
                   const char *value) {
  (void)section;
  if (strcmp(name, "greeting") == 0) {
    snprintf((char *)user, 64, "%s", value);
  }
  return 1;
}

int main(void) {
  char greeting[64] = "";
  ini_parse_string("[s]\ngreeting = external\n", handler, greeting);
  printf("%s, zlib %s\n", greeting, zlibVersion());
  return 0;
}
