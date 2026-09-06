/* V2 (clean OOB read) and V3 (ENROLL_ATTEMPT_DELETE fixed-size memcpy). */
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <sys/param.h>
#define ELANMOC2_USER_ID_MAX_LEN (64 - 2)   /* 62 */

int main (int argc, char **argv)
{
  if (atoi (argv[1]) == 2)
    {
      /* V2: gsize underflow defeats the MIN() bound. 0C5E offset = 3,
       * device reply = 2 bytes -> 2 - 3 wraps. Copy to a separate dest so
       * the overflow is reported against the device reply itself. */
      fprintf (stderr, "== V2: underflow -> OOB read of device reply ==\n");
      guint8 *reply = g_malloc (2);              /* exactly 2 bytes */
      reply[0] = 0x40; reply[1] = 0xff;
      GBytes *b = g_bytes_new_take (reply, 2);
      guint offset = 3;
      guint max_len = MIN (61, g_bytes_get_size (b) - offset);
      fprintf (stderr, "    computed max_len = %u  (from a 2-byte reply!)\n", max_len);
      guint8 *dest = g_malloc0 (256);
      const guint8 *data = g_bytes_get_data (b, NULL);
      memcpy (dest, &data[offset], max_len);     /* <-- OOB read */
      fprintf (stderr, "    (no crash)\n");
    }
  else
    {
      /* V3: ENROLL_ATTEMPT_DELETE copies a hardcoded 62 bytes out of a
       * GBytes whose real size is 0 on 04f3:0c00. */
      fprintf (stderr, "== V3: enroll-delete fixed-size memcpy ==\n");
      GByteArray *empty = g_byte_array_new ();
      g_byte_array_set_size (empty, 0);
      GBytes *user_id = g_byte_array_free_to_bytes (empty);
      gsize user_id_bytes = MIN (72 - 4, ELANMOC2_USER_ID_MAX_LEN);  /* 62 */
      fprintf (stderr, "    user_id real size = %zu, memcpy len = %zu, src = %p\n",
               g_bytes_get_size (user_id), user_id_bytes,
               g_bytes_get_data (user_id, NULL));
      guint8 *buffer_out = g_malloc0 (72);
      memcpy (&buffer_out[4], g_bytes_get_data (user_id, NULL), user_id_bytes);
      fprintf (stderr, "    (no crash)\n");
    }
  return 0;
}
