/* Same three inputs, against the PATCHED helper logic (copied verbatim from
 * the fixed elanmoc2.c) plus the fixed ENROLL_ATTEMPT_DELETE bound. */
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <sys/param.h>
#define MAXLEN(is0c5e) ((is0c5e) ? (64-3) : (64-2))

static gchar *
get_user_id_string_fixed (gboolean is_0c5e, GBytes *resp, gsize *out_len)
{
  gsize resp_len = 0;
  const guint8 *data = g_bytes_get_data (resp, &resp_len);
  const gsize offset = is_0c5e ? 3 : 2;
  gsize max_len = 0;

  if (data != NULL && resp_len > offset)
    max_len = MIN ((gsize) MAXLEN (is_0c5e), resp_len - offset);

  gchar *user_id = g_malloc0 (max_len + 1);
  if (max_len > 0)
    memcpy (user_id, &data[offset], max_len);
  if (out_len != NULL)
    *out_len = max_len;
  return user_id;
}

static void one (const char *label, gboolean is_0c5e, const guint8 *r, gsize n)
{
  guint8 *heap = g_malloc (n); memcpy (heap, r, n);
  GBytes *b = g_bytes_new_take (heap, n);
  gsize len = 0;
  g_autofree gchar *uid = get_user_id_string_fixed (is_0c5e, b, &len);

  /* consumer 1: used as a C string */
  gboolean fp = g_str_has_prefix (uid, "FP");
  /* consumer 2: ENROLL_ATTEMPT_DELETE with the fixed bound */
  gsize n_copy = MIN ((gsize) 72 - 4, len);
  guint8 *out = g_malloc0 (72);
  if (n_copy > 0) memcpy (&out[4], uid, n_copy);

  fprintf (stderr, "  %-42s len=%2zu  copy=%2zu  strprefix_ok=%d  uid=\"%s\"\n",
           label, len, n_copy, fp, uid);
  g_free (out); g_bytes_unref (b);
}

int main (void)
{
  const guint8 short_reply[2] = { 0x40, 0xff };          /* real 0c00 reply */
  guint8 good[64]; memset (good, 0, sizeof good);
  good[0] = 0x40; good[1] = 0x00;
  memcpy (&good[2], "FP1-abcdef0123", 14);               /* well-formed 0c4c */
  const guint8 one_byte[1] = { 0x40 };
  const guint8 empty[1] = { 0 };

  fprintf (stderr, "== patched helper, adversarial + normal replies ==\n");
  one ("V1  2-byte reply, offset 2 (0c00)",  FALSE, short_reply, 2);
  one ("V2  2-byte reply, offset 3 (0C5E)",  TRUE,  short_reply, 2);
  one ("    1-byte reply, offset 2",         FALSE, one_byte,    1);
  one ("    0-byte reply, offset 2",         FALSE, empty,       0);
  one ("    64-byte well-formed reply",      FALSE, good,        64);
  one ("    64-byte well-formed, 0C5E",      TRUE,  good,        64);
  fprintf (stderr, "== all returned cleanly ==\n");
  return 0;
}
