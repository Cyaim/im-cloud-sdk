using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using NUnit.Framework;

namespace Cyaim.Im.Tests
{
    /// <summary>
    /// The version-drift guard: five manifests, five constants, one number.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>sdk/CONTRACT.md</c> §9.1 makes the SDK version lockstep across all five platforms, because
    /// a version number that identifies a <i>contract</i> answers "which endpoints do you have"
    /// without anyone having to ask which platform the customer is on. Lockstep that nothing checks
    /// is a convention, and a convention survives exactly until the first release where only one
    /// platform changed.
    /// </para>
    /// <para>
    /// The identical assertion exists in the other four suites, and in all five it hangs off the
    /// command CI actually runs. The Kotlin guard this generalises was wired to Gradle's
    /// <c>check</c> while CI ran <c>test</c>, so from the day it was written it had never once
    /// executed — a guard the pipeline does not run is a comment.
    /// </para>
    /// <para>
    /// The repository is located from <see cref="CallerFilePathAttribute"/> rather than from the
    /// working directory: the Unity test runner's working directory is the project root, a
    /// command-line proxy build's is wherever it was invoked, and neither is somewhere this file can
    /// count on. The compiler bakes in the path of this source file, which is inside the repository
    /// by construction.
    /// </para>
    /// <para>
    /// 五个平台的版本号必须一致（契约 §9.1）；这条断言挂在 test 上，
    /// 而不是某个 CI 根本不会执行的任务上。
    /// </para>
    /// </remarks>
    [TestFixture]
    public sealed class VersionGuardTests
    {
        private static string SdkRoot([CallerFilePath] string here = null)
        {
            var directory = Path.GetDirectoryName(here);

            for (var hop = 0; hop < 8 && !string.IsNullOrEmpty(directory); hop++)
            {
                if (File.Exists(Path.Combine(directory, "endpoint-inventory.json")))
                {
                    return directory;
                }

                directory = Path.GetDirectoryName(directory);
            }

            throw new InvalidOperationException("could not locate sdk/endpoint-inventory.json from " + here);
        }

        private static string Read(string relative)
        {
            return File.ReadAllText(Path.Combine(SdkRoot(), relative.Replace('/', Path.DirectorySeparatorChar)));
        }

        private static string Capture(string text, string pattern, string what)
        {
            var match = Regex.Match(text, pattern, RegexOptions.Multiline);
            Assert.That(match.Success, Is.True, "could not read " + what);
            return match.Groups[1].Value;
        }

        /// <summary>
        /// Every place a package version is written down. Swift has no manifest field — SPM takes
        /// its version from a git tag — so its constant is the source of truth there.
        /// </summary>
        private static Dictionary<string, string> DeclaredVersions()
        {
            return new Dictionary<string, string>(StringComparer.Ordinal)
            {
                {
                    "typescript/package.json",
                    Capture(Read("typescript/package.json"), "\"version\"\\s*:\\s*\"([^\"]+)\"", "the npm version")
                },
                {
                    "unity/package.json",
                    Capture(Read("unity/package.json"), "\"version\"\\s*:\\s*\"([^\"]+)\"", "the UPM version")
                },
                {
                    "kotlin/build.gradle.kts",
                    Capture(Read("kotlin/build.gradle.kts"), "^version\\s*=\\s*\"([^\"]+)\"", "the Gradle version")
                },
                {
                    "flutter/pubspec.yaml",
                    Capture(Read("flutter/pubspec.yaml"), "^version:\\s*(\\S+)", "the pubspec version")
                },
                {
                    "swift/Sources/CyaimIM/ImSdk.swift",
                    Capture(
                        Read("swift/Sources/CyaimIM/ImSdk.swift"),
                        "packageVersion\\s*=\\s*\"([^\"]+)\"",
                        "Swift's packageVersion")
                },
            };
        }

        [Test]
        public void ImSdk_PackageVersion_equals_package_json()
        {
            var manifest = Capture(
                Read("unity/package.json"),
                "\"version\"\\s*:\\s*\"([^\"]+)\"",
                "the UPM version");

            Assert.That(
                ImSdk.PackageVersion,
                Is.EqualTo(manifest),
                "UPM resolves the manifest and the handshake sends the constant; a disagreement " +
                "means a support ticket quotes a version that was never released");
        }

        [Test]
        public void All_five_platforms_ship_one_version()
        {
            var declared = DeclaredVersions();
            var distinct = new HashSet<string>(declared.Values, StringComparer.Ordinal);

            Assert.That(
                distinct.Count,
                Is.EqualTo(1),
                "the five SDKs must ship one version number (CONTRACT §9.1), found " +
                string.Join(", ", Flatten(declared)));

            foreach (var only in distinct)
            {
                Assert.That(ImSdk.PackageVersion, Is.EqualTo(only));
            }
        }

        [Test]
        public void ImSdk_ContractVersion_equals_endpoint_inventory()
        {
            var inventory = Capture(
                Read("endpoint-inventory.json"),
                "\"contractVersion\"\\s*:\\s*\"([^\"]+)\"",
                "the inventory's contractVersion");

            Assert.That(
                ImSdk.ContractVersion,
                Is.EqualTo(inventory),
                "the contract version is generated into the inventory; the constant follows it");
        }

        private static IEnumerable<string> Flatten(Dictionary<string, string> declared)
        {
            foreach (var entry in declared)
            {
                yield return entry.Key + "=" + entry.Value;
            }
        }
    }
}
