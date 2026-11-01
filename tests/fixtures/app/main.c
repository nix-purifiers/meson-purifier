#include <stdio.h>
#include <string.h>

#include <cjson/cJSON.h>
#include <ini.h>
#include <tinyexpr.h>
#include <yaml.h>
#include <zlib.h>

#include "greeting.h"
#include "hghooks.h"
#include "svn_examples.h"

#ifndef TINYEXPR_PURIFIED
#error "the wrap's diff_files did not reach tinyexpr.h"
#endif

static int on_entry(void *user, const char *section, const char *name, const char *value) {
  (void)section;
  if (strcmp(name, "greeting") == 0) {
    snprintf((char *)user, 64, "%s", value);
  }
  return 1;
}

int main(void) {
  /* zlib: a round trip through compress and uncompress. */
  const char *text = purifier_greeting();
  unsigned char packed[128];
  unsigned char unpacked[128];
  uLongf packed_size = sizeof packed;
  uLongf unpacked_size = sizeof unpacked;
  if (compress(packed, &packed_size, (const Bytef *)text, strlen(text) + 1) != Z_OK ||
      uncompress(unpacked, &unpacked_size, packed, packed_size) != Z_OK ||
      strcmp((const char *)unpacked, text) != 0) {
    fprintf(stderr, "zlib round trip failed\n");
    return 1;
  }

  /* inih: a value from an INI string. */
  char greeting[64] = "";
  if (ini_parse_string("[fixture]\ngreeting = hello\n", on_entry, greeting) != 0 ||
      strcmp(greeting, "hello") != 0) {
    fprintf(stderr, "inih parse failed\n");
    return 1;
  }

  /* tinyexpr: an expression. */
  double value = te_interp("2 + 3 * 4", 0);
  if (value != 14.0) {
    fprintf(stderr, "tinyexpr returned %f\n", value);
    return 1;
  }

  /* cJSON: a parsed object. */
  cJSON *json = cJSON_Parse("{\"answer\": 42}");
  cJSON *answer = cJSON_GetObjectItem(json, "answer");
  if (!cJSON_IsNumber(answer) || answer->valueint != 42) {
    fprintf(stderr, "cJSON parse failed\n");
    return 1;
  }
  cJSON_Delete(json);

  /* The Mercurial and Subversion checkouts reached the build. */
  if (HGHOOKS_README_SIZE <= 0 || SVN_EXAMPLE_SIZE <= 0) {
    fprintf(stderr, "a checkout is empty\n");
    return 1;
  }

  printf("%s, %s, %g, libyaml %s, hg %d bytes, svn %d bytes\n", unpacked, greeting, value,
         yaml_get_version_string(), HGHOOKS_README_SIZE, SVN_EXAMPLE_SIZE);
  return 0;
}
