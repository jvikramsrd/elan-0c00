/* Zero-risk libfprint integration probe for ELAN 04f3:0c00.
 *
 * Enumerates devices through the freshly built libfprint, reports what the
 * driver advertises, then opens and immediately closes the device.
 *
 * elanmoc2_open() performs only g_usb_device_reset() + claim_interface(); it
 * sends no protocol commands. Nothing here enrolls, deletes, or wipes.
 */
#include <fprint.h>
#include <glib.h>

static const char *
scan_type_str (FpScanType t)
{
  switch (t)
    {
    case FP_SCAN_TYPE_SWIPE: return "swipe";
    case FP_SCAN_TYPE_PRESS: return "press";
    default: return "?";
    }
}

int
main (void)
{
  g_autoptr(FpContext) ctx = fp_context_new ();
  GPtrArray *devs = fp_context_get_devices (ctx);

  if (!devs || devs->len == 0)
    {
      g_print ("no devices found\n");
      return 1;
    }

  g_print ("libfprint sees %u device(s)\n\n", devs->len);

  for (guint i = 0; i < devs->len; i++)
    {
      FpDevice *d = g_ptr_array_index (devs, i);
      g_autoptr(GError) err = NULL;

      g_print ("device %u\n", i);
      g_print ("  driver          %s\n", fp_device_get_driver (d));
      g_print ("  name            %s\n", fp_device_get_name (d));
      g_print ("  device id       %s\n", fp_device_get_device_id (d));
      g_print ("  scan type       %s\n", scan_type_str (fp_device_get_scan_type (d)));
      g_print ("  enroll stages   %d\n", fp_device_get_nr_enroll_stages (d));
      g_print ("  has storage     %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_STORAGE) ? "yes" : "no");
      g_print ("  can identify    %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_IDENTIFY) ? "yes" : "no");
      g_print ("  can verify      %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_VERIFY) ? "yes" : "no");
      g_print ("  storage list    %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_STORAGE_LIST) ? "yes" : "no");
      g_print ("  storage delete  %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_STORAGE_DELETE) ? "yes" : "no");
      g_print ("  storage clear   %s\n",
               fp_device_has_feature (d, FP_DEVICE_FEATURE_STORAGE_CLEAR) ? "yes" : "no");

      g_print ("  opening (USB reset + claim, no protocol commands)... ");
      if (!fp_device_open_sync (d, NULL, &err))
        {
          g_print ("FAILED: %s\n", err->message);
          continue;
        }
      g_print ("ok\n");

      g_print ("  closing... ");
      g_autoptr(GError) cerr = NULL;
      if (!fp_device_close_sync (d, NULL, &cerr))
        g_print ("FAILED: %s\n", cerr->message);
      else
        g_print ("ok\n");
    }

  return 0;
}
