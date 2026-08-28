using System;
using UnityEngine;

namespace Cyaim.Im
{
    /// <summary>Fills in the two handshake fields a game should not have to think about.</summary>
    public static class ImDevice
    {
        /// <summary>PlayerPrefs key holding the generated device id.</summary>
        public const string DeviceIdPreferenceKey = "cyaim.im.deviceId";

        /// <summary>
        /// Returns a device id that is stable for this installation, generating and storing one on
        /// first call.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Stability is not cosmetic. The multi-device policy uses this value to tell "the same
        /// device reconnecting" from "a second device logging in"; a value that changes every launch
        /// makes a player kick themselves offline, and under <c>SingleDevice</c> it makes the app
        /// unusable. Every support ticket that begins "it randomly logs me out" starts here.
        /// </para>
        /// <para>
        /// A random GUID in <c>PlayerPrefs</c> rather than <c>SystemInfo.deviceUniqueIdentifier</c>:
        /// the hardware id is unavailable or randomised on several platforms, and on the ones where
        /// it does work it is a persistent hardware identifier, which is a privacy review nobody
        /// asked for. This value identifies an install, which is all the policy needs.
        /// </para>
        /// </remarks>
        public static string GetOrCreateDeviceId(string preferenceKey = DeviceIdPreferenceKey)
        {
            var existing = PlayerPrefs.GetString(preferenceKey, null);
            if (!string.IsNullOrEmpty(existing))
            {
                return existing;
            }

            var generated = Guid.NewGuid().ToString("N");
            PlayerPrefs.SetString(preferenceKey, generated);
            PlayerPrefs.Save();
            return generated;
        }

        /// <summary>
        /// Maps the running Unity platform onto the protocol platform code.
        /// </summary>
        /// <remarks>
        /// The server uses this for offline push routing and for the per-platform multi-login rules,
        /// so an editor session reports the desktop OS it is running on rather than a special
        /// "editor" value — otherwise testing in the editor would not exercise the same policy the
        /// player will hit.
        /// </remarks>
        public static ImPlatform DetectPlatform()
        {
            switch (Application.platform)
            {
                case RuntimePlatform.IPhonePlayer:
                    return ImPlatform.iOS;

                case RuntimePlatform.Android:
                    return ImPlatform.Android;

                case RuntimePlatform.WindowsPlayer:
                case RuntimePlatform.WindowsEditor:
                case RuntimePlatform.WindowsServer:
                case RuntimePlatform.WSAPlayerX64:
                case RuntimePlatform.WSAPlayerX86:
                case RuntimePlatform.WSAPlayerARM:
                    return ImPlatform.Windows;

                case RuntimePlatform.OSXPlayer:
                case RuntimePlatform.OSXEditor:
                case RuntimePlatform.OSXServer:
                    return ImPlatform.macOS;

                case RuntimePlatform.WebGLPlayer:
                    return ImPlatform.Web;

                case RuntimePlatform.LinuxPlayer:
                case RuntimePlatform.LinuxEditor:
                case RuntimePlatform.LinuxServer:
                    return ImPlatform.Linux;

                default:
                    return ImPlatform.Unknown;
            }
        }
    }
}
