"""Lock the MTLCompilerService adapter to RE-verified executable identities.

The adapter is fail-closed: an executable whose UUID is not allowlisted, or
whose instructions do not match the layout recorded for that UUID, keeps stock
behavior.  These tests assert that property for every build we have actually
measured, and that supporting a new build means adding a row to *both* the UUID
allowlist and the index-aligned layout table -- never editing the old row.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "MTLCompilerBypassOSCheck/Tweak.x").read_text()


class MTLCompilerServiceIdentity(unittest.TestCase):
    def setUp(self):
        self.adapter = SOURCE.split(
            "static void InstallMacOSMetalTargetAdapter(void) {", 1
        )[1].split("static void InstallLegacyTargetBypasses(void) {", 1)[0]

    def allowlist_entries(self):
        body = self.adapter.split("expectedUUIDs[][16] = {", 1)[1].split("};", 1)[0]
        return [chunk for chunk in body.split("},") if "0x" in chunk]

    def layout_rows(self):
        body = self.adapter.split("expectedLayouts[] = {", 1)[1].split("};", 1)[0]
        return [row for row in body.splitlines() if "0x" in row]

    def test_verified_ios_16_identities_are_both_allowlisted(self):
        self.assertIn(
            "0x6d, 0x2c, 0xfe, 0x56, 0x8d, 0x88, 0x39, 0xaa,",
            self.adapter,
        )
        self.assertIn(
            "0xb4, 0x74, 0x53, 0x94, 0x88, 0xd0, 0x37, 0x39,",
            self.adapter,
        )
        self.assertIn(
            "iOS 16.3.1 (20D67) UUID 6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E",
            self.adapter,
        )
        self.assertIn(
            "iOS 16.0   (20A8372) UUID B4745394-88D0-3739-9E17-4DE2FB12B00E",
            self.adapter,
        )

    def test_ipados_16_5_1_identity_is_allowlisted(self):
        # Measured on iPad14,3 (iPad Pro 11" M2), iPadOS 16.5.1 (20F75).
        self.assertIn(
            "0xb5, 0xcb, 0xf4, 0x57, 0xb3, 0x00, 0x3f, 0xd0,",
            self.adapter,
        )
        self.assertIn(
            "iPadOS 16.5.1 (20F75) UUID B5CBF457-B300-3FD0-A646-1261DA6E86B0",
            self.adapter,
        )

    def test_every_allowlisted_build_has_an_index_aligned_layout(self):
        self.assertIn("struct MacWSTargetAdapterLayout", self.adapter)
        self.assertIn(
            "static const struct MacWSTargetAdapterLayout expectedLayouts[]",
            self.adapter,
        )
        self.assertIn("callSites[i].offset = layout->callOffsets[i];",
                      self.adapter)
        # One layout row per allowlisted UUID, matched by index.
        self.assertEqual(len(self.layout_rows()), len(self.allowlist_entries()))
        # The reply call site moves with the executable, so it must come from
        # the matched layout rather than one hardcoded 20D67 offset.
        self.assertIn("const uint32_t expectedReplyCall = layout->replyCall;",
                      self.adapter)

    def test_unknown_service_builds_keep_stock_behavior(self):
        self.assertIn("static const uint8_t expectedUUIDs[][16]", self.adapter)
        self.assertIn("if (matchedBuild < 0 ||", self.adapter)
        self.assertIn("MTLCompilerService UUID mismatch", self.adapter)
        self.assertIn("return;", self.adapter)

    def test_each_allowlisted_build_still_requires_instruction_validation(self):
        for offset in ("0x20e8", "0x25f0", "0x2628"):
            self.assertIn(offset, self.adapter)
        self.assertIn("if (*callSite != callSites[i].expected)", self.adapter)
        self.assertIn("target adapter: validation failed", self.adapter)
        # The 20F75 layout is the -0x98 shift, not a copy of the 20D67 row.
        self.assertIn("{0x2050, 0x2558, 0x2590}", self.adapter)
        self.assertIn("0x2770, 0x9400047c", self.adapter)
        self.assertIn("0x26d8, 0x940004ae", self.adapter)


class CompilerABIIdentity(unittest.TestCase):
    """libGPUCompilerImpl / libComposeFilters / libLLVM candidate tables."""

    def setUp(self):
        self.dag_adapter = SOURCE.split(
            "static bool InstallCatalystDAGTargetContext(void) {", 1
        )[1].split("static MacWSTripleABI", 1)[0]
        self.filter_adapter = SOURCE.split(
            "static bool InstallImageFilterTargetContext(void) {", 1
        )[1]

    def test_dag_triple_identities_are_allowlisted_with_fixed_prologue(self):
        # Both measured builds are allowlisted ...
        self.assertIn("0x41,0xd2,0xf0,0x61,0x8d,0xa8,0x3c,0xfa,", self.dag_adapter)
        self.assertIn("0xd4,0x99,0xf4,0x99,0x45,0xeb,0x38,0x8b,", self.dag_adapter)
        # ... and the prologue, which did not change between them, stays
        # mandatory.
        self.assertIn(
            "{0xd503237f, 0xd10283ff, 0xa9065ff8, 0xa90757f6}",
            self.dag_adapter,
        )

    def test_image_filter_candidates_move_as_one_unit(self):
        self.assertIn("composeUUIDs", self.filter_adapter)
        self.assertIn("llvmUUIDs", self.filter_adapter)
        self.assertIn("composeOffsets[] = {0x9bb8, 0x9e8c}", self.filter_adapter)
        self.assertIn("getTargetOffsets[] = {0x844fb0, 0x84e734}",
                      self.filter_adapter)
        self.assertIn("setTargetOffsets[] = {0x844fcc, 0x84e750}",
                      self.filter_adapter)
        # 16.5.1 grew the frame by 0x10; reusing the 16.3 prologue would make
        # the check fail closed on the new build.
        self.assertIn("{0xd503237f,0xd10483ff,0xa90c6ffc,0xa90d67fa}",
                      self.filter_adapter)
        self.assertIn("candidate tables misaligned", self.filter_adapter)
        self.assertIn("if (!compilerABIMatched)", self.filter_adapter)


if __name__ == "__main__":
    unittest.main()
