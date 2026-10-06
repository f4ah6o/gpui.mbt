import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(HERE))
import build_manifest as build
import candidate_bundle as bundles
import case_runner as runner
import input_cases


class CandidateBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init","-q")
        (self.repo / "source.mbt").write_text("baseline\n")
        self.git("add","source.mbt")
        self.git("-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture","--no-gpg-sign")
        self.profile = self.root / "profile"
        self.prefix = self.profile / "prefix"
        self.prefix.mkdir(parents=True)
        self.fontconfig = self.profile / "fonts.conf"
        self.fontconfig.write_text("<fontconfig/>\n")
        self.compiler = self.profile / "compiler"
        self.compiler.write_bytes(b"fixture toolchain")
        self.app = self.profile / "build-app"
        self.app.write_bytes(b"candidate one")
        self.app.chmod(0o755)
        for name in runner.XKB_RESOURCES:
            path = self.prefix / "usr/share/X11/xkb" / name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text("fixture xkb resource")
        self.font_directory=self.profile/"fonts"
        self.font_directory.mkdir()
        self.font=self.font_directory/"fixture.ttf"
        self.font.write_bytes(b"fixture font")
        self.fc_list=self.profile/"fc-list-fixture"
        self.fc_list.write_text("#!/usr/bin/python3\nfrom pathlib import Path\n"+
                                "for path in sorted(Path("+repr(str(self.font_directory))+").glob('*.ttf')): print(path)\n")
        self.fc_list.chmod(0o755)
        self.runtime = {"profile_root":str(self.profile),"prefix":str(self.prefix),"fontconfig":str(self.fontconfig),
                        "files":[build.file_identity(self.fontconfig,"fontconfig"),build.file_identity(self.compiler,"tool:fixture"),
                                 build.file_identity(self.fc_list,"tool:fc-list"),build.file_identity(self.font,"configured-font")],
                        "trees":[{"role":"fixture-prefix","path":str(self.prefix),"sha256":build.tree_digest(self.prefix)}],
                        "versions":{"fixture":"1"},"generated_protocols":[]}

    def git(self,*args):
        return subprocess.check_output(["git","-C",str(self.repo),*args],stderr=subprocess.STDOUT)

    def manifest(self):
        source = build.capture_source(self.repo)
        path = self.profile / "field-build.json"
        build.write_build_manifest(path,source,source,self.app,self.runtime,["fixture-build"])
        return path

    def prepare(self,name="candidate"):
        output=self.root/name
        bundles.prepare_from_build(self.manifest(),output)
        return output

    def test_two_build_outputs_reuse_identical_semantic_case_bytes(self):
        semantic = (HERE / "fixtures/cases/basic-text-shift.json").read_bytes()
        first=self.prepare("one")
        first_manifest,first_runtime=bundles.verify_candidate(first)
        self.app.write_bytes(b"different rebuild two")
        second=self.prepare("two")
        second_manifest,second_runtime=bundles.verify_candidate(second)
        self.assertNotEqual(first_runtime["app_sha256"],second_runtime["app_sha256"])
        self.assertEqual(semantic,(HERE / "fixtures/cases/basic-text-shift.json").read_bytes())
        self.assertEqual(input_cases.load_case(HERE / "fixtures/cases/basic-text-shift.json")["version"],2)
        self.assertEqual(first_runtime["app"].read_bytes(),b"candidate one")
        self.assertEqual(second_runtime["app"].read_bytes(),b"different rebuild two")
        # The old build-output path can change; the actual copied executable is checked.
        bundles.verify_candidate(first)
        self.assertEqual(first_manifest["mode"],"built")
        self.assertEqual(first_manifest["source"]["head"],second_manifest["source"]["head"])

    def test_preparation_is_deterministic_and_outside_repo(self):
        one=self.prepare("one")
        two=self.prepare("two")
        self.assertEqual((one/"manifest.json").read_bytes(),(two/"manifest.json").read_bytes())
        with self.assertRaisesRegex(RuntimeError,"outside the repository"):
            bundles.prepare_from_build(self.manifest(),self.repo/"candidate")
        old_hash=bundles.digest(one/"app")
        with self.assertRaisesRegex(RuntimeError,"fresh directory"):
            bundles.prepare_from_build(self.manifest(),one)
        self.assertEqual(old_hash,bundles.digest(one/"app"))

    def test_copied_files_and_manifest_tampering_are_rejected(self):
        for name in ("app","tracked-source.patch","fonts.conf","build-manifest.json","manifest.json"):
            with self.subTest(name=name):
                bundle=self.prepare("tamper-"+name.replace(".","-"))
                path=bundle/name
                path.chmod(0o700)
                path.write_bytes(path.read_bytes()+b"changed")
                with self.assertRaisesRegex(RuntimeError,"changed candidate"):
                    bundles.verify_candidate(bundle)

    def test_source_and_external_toolchain_and_fontconfig_drift_stop_run(self):
        bundle=self.prepare()
        original=(self.repo/"source.mbt").read_bytes()
        (self.repo/"source.mbt").write_text("changed source\n")
        with self.assertRaisesRegex(RuntimeError,"source changed"):
            bundles.verify_candidate(bundle)
        (self.repo/"source.mbt").write_bytes(original)
        for path in (self.compiler,self.fontconfig,self.font):
            old=path.read_bytes()
            path.write_bytes(old+b"changed")
            with self.assertRaisesRegex(RuntimeError,"captured runtime file changed"):
                bundles.verify_candidate(bundle)
            path.write_bytes(old)

    def test_new_configured_font_is_detected_without_changing_old_font_bytes(self):
        bundle=self.prepare()
        (self.font_directory/"new.ttf").write_bytes(b"new font")
        with self.assertRaisesRegex(RuntimeError,"font inventory"):
            bundles.verify_candidate(bundle)

    def test_dirty_tracked_patch_and_untracked_identity_are_exact(self):
        (self.repo/"source.mbt").write_text("dirty tracked source\n")
        (self.repo/"new-source.mbt").write_text("untracked source\n")
        bundle=self.prepare()
        manifest,_=bundles.verify_candidate(bundle)
        self.assertTrue((bundle/"tracked-source.patch").read_bytes())
        self.assertEqual(manifest["source"]["untracked_files"][0]["relative_path"],"new-source.mbt")
        (self.repo/"new-source.mbt").write_text("different untracked source\n")
        with self.assertRaisesRegex(RuntimeError,"source changed"):
            bundles.verify_candidate(bundle)

    def test_explicit_bound_mode_does_not_claim_compilation(self):
        captured=build.make_bound_manifest(self.repo,self.app,self.runtime)
        output=self.root/"bound"
        bundles.prepare_manifest(captured,output)
        manifest,_=bundles.verify_candidate(output)
        self.assertEqual(manifest["mode"],"bound")
        self.assertIn("compilation attribution not established",manifest["source_claim"])

    def test_live_fontconfig_base_is_retained(self):
        bundle=self.prepare()
        _,runtime=bundles.verify_candidate(bundle)
        self.assertEqual(runtime["fontconfig"],self.fontconfig)
        self.assertNotEqual(runtime["fontconfig"],bundle/"fonts.conf")
        self.assertEqual((bundle/"fonts.conf").read_bytes(),self.fontconfig.read_bytes())

    def test_runner_accepts_two_candidates_without_fixture_repinning(self):
        import argparse
        one=self.prepare("one")
        self.app.write_bytes(b"rebuilt app")
        two=self.prepare("two")
        case=input_cases.select_case("basic-text-shift")
        for candidate in (one,two):
            args=argparse.Namespace(candidate=candidate,prefix=None,repo=None,app=None,app_sha256=None,fontconfig=None,source_patch=None,golden=None)
            source,golden=runner.verify_inputs(case,args)
            self.assertEqual(source["app_sha256"],bundles.digest(candidate/"app"))
            self.assertEqual(source["candidate_mode"],"built")
            self.assertEqual(args.app,candidate/"app")
            self.assertEqual(golden,HERE/"fixtures/field-six-keys.png")
        args=argparse.Namespace(candidate=one,prefix=self.prefix)
        with self.assertRaisesRegex(RuntimeError,"cannot override"):
            runner.verify_inputs(case,args)

    def test_cli_prepare_verify_do_not_launch_app_or_connect_display(self):
        output=self.root/"cli"
        path=self.manifest()
        with patch("sys.stdout",new=io.StringIO()),patch.object(runner.C,"CDLL") as library:
            self.assertEqual(bundles.main(["prepare","--build-manifest",str(path),"--output",str(output)]),0)
            self.assertEqual(bundles.main(["verify",str(output)]),0)
            library.assert_not_called()


if __name__=="__main__":
    unittest.main()
