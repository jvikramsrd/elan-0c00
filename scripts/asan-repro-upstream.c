/* Reproducer for elanmoc2_get_user_id_string() memory-safety bugs.
 * Logic copied verbatim from libfprint elanmoc2.c @ 11f0316d (lines 231-250),
 * with the driver types reduced to plain values. */
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <sys/param.h>

#define ELANMOC2_USER_ID_MAX_LEN      (64 - 2)   /* cmd_finger_info.in_len - 2 */
#define ELANMOC2_USER_ID_MAX_LEN_0C5E (64 - 3)

/* --- VERBATIM UPSTREAM LOGIC --- */
static GBytes *
get_user_id_string_upstream (gboolean is_0c5e, GBytes *finger_info_response)
{
  GByteArray *user_id = g_byte_array_new ();

  guint offset = is_0c5e ? 3 : 2;
  guint max_len = MIN (is_0c5e ? ELANMOC2_USER_ID_MAX_LEN_0C5E
                               : ELANMOC2_USER_ID_MAX_LEN,
                       g_bytes_get_size (finger_info_response) - offset);

  g_byte_array_set_size (user_id, max_len);

  const guint8 *data = g_bytes_get_data (finger_info_response, NULL);
  fprintf (stderr, "    [max_len=%u  array->data=%p]\n", max_len,
           (void *) user_id->data);
  memcpy (user_id->data, &data[offset], max_len);
  user_id->data[max_len] = '\0';

  return g_byte_array_free_to_bytes (user_id);
}

int main (int argc, char **argv)
{
  int which = argc > 1 ? atoi (argv[1]) : 0;

  if (which == 0)
    {
      /* V1: the real 04f3:0c00 finger_info reply is 2 bytes: 40 ff */
      fprintf (stderr, "== V1: 2-byte reply, normal device (offset 2) ==\n");
      guint8 reply[2] = { 0x40, 0xff };
      GBytes *b = g_bytes_new (reply, sizeof (reply));
      g_bytes_unref (get_user_id_string_upstream (FALSE, b));
      g_bytes_unref (b);
    }
  else
    {
      /* V2: reply shorter than offset -> gsize underflow */
      fprintf (stderr, "== V2: 2-byte reply, 0C5E device (offset 3) ==\n");
      guint8 reply[2] = { 0x40, 0xff };
      GBytes *b = g_bytes_new (reply, sizeof (reply));
      g_bytes_unref (get_user_id_string_upstream (TRUE, b));
      g_bytes_unref (b);
    }
  fprintf (stderr, "    (returned without crashing)\n");
  return 0;
}
