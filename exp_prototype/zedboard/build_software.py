"""Build Secure and Normal firmware using the Vitis 2025.2 Python environment.

Reads released platform/source inputs and the external build directory's XSA;
writes a new platform/BSP, ELF images, and software_build_status.json outside
the prototype. ENF_BUILD_DIR must select a fresh workspace after the hardware
build. This helper builds software without programming or executing a board.
"""
import json
import os
from pathlib import Path
import shutil
import zipfile

import vitis


def main():
    """Build a fresh external Vitis platform and firmware, recording build status even on failure."""
    # STEP_1: Locate release inputs and require a fresh external workspace.
    repository = Path(__file__).resolve().parents[1]
    if not os.environ.get("ENF_BUILD_DIR"):
        raise RuntimeError("Set ENF_BUILD_DIR to the hardware helper's external build directory")
    build = Path(os.environ["ENF_BUILD_DIR"]).expanduser().resolve()
    if build == repository or repository in build.parents:
        raise RuntimeError("ENF_BUILD_DIR must be outside the repository")
    if not build.is_dir():
        raise RuntimeError("Run build_hardware.tcl first")
    workspace = build / "vitis"
    result = {"status": "FAIL", "applications": {}}
    try:
        if workspace.exists():
            raise RuntimeError("Use a fresh build directory; Vitis workspace already exists")
        xsa = build / "artifacts/enf_clean.xsa"
        with zipfile.ZipFile(xsa) as archive:
            if archive.testzip() is not None or not any(n.endswith(".bit") for n in archive.namelist()):
                raise RuntimeError("Fresh XSA must be intact and contain the bitstream")
        config = json.loads((repository / "zedboard/platform/enf_zb_attester_platform/vitis-comp.json").read_text())
        domain = "standalone_ps7_cortexa9_0"
        if not any(d["name"] == domain and d["processor"] == "ps7_cortexa9_0" and d["os"] == "standalone"
                   for d in config["configuration"]["domains"]):
            raise RuntimeError("Released platform does not define the expected standalone CPU0 domain")

        # STEP_2: Generate the platform/BSP and register its new export.
        workspace.mkdir()
        client = vitis.create_client()
        client.set_workspace(str(workspace))
        platform = client.create_platform_component(
            name="enf_zb_attester_platform", hw_design=str(xsa), os="standalone",
            cpu="ps7_cortexa9_0", domain_name=domain, no_boot_bsp=False,
            generate_dtb=False, compiler="gcc")
        platform.build()
        export = workspace / "enf_zb_attester_platform/export/enf_zb_attester_platform"
        xpfm = export / "enf_zb_attester_platform.xpfm"
        bsp = export / "sw" / domain
        if not xpfm.is_file() or not (bsp / "lib/libxil.a").is_file():
            raise RuntimeError("Fresh platform export/BSP missing")
        client.add_platform_repos(str(export))

        # STEP_3: Copy unchanged application inputs and rebind generated paths.
        for role, name in (("secure_world", "enf_zb_secure"), ("normal_world", "enf_zb_normal")):
            app = client.create_app_component(
                name=name, platform=str(xpfm), domain=domain, template="empty_application")
            destination = workspace / name / "src"
            generated_paths = {line.split(":", 1)[0]: line for line in
                               (destination / "app.yaml").read_text().splitlines()
                               if line.startswith(("domain_path:", "app_src_dir:"))}
            if set(generated_paths) != {"domain_path", "app_src_dir"}:
                raise RuntimeError("Generated application paths missing")
            for source in (repository / "zedboard" / role / "src").iterdir():
                if source.is_file():
                    shutil.copy2(source, destination / source.name)
            metadata = destination / "app.yaml"
            lines = metadata.read_text().splitlines()
            metadata.write_text("\n".join(generated_paths.get(line.split(":", 1)[0], line)
                                          for line in lines) + "\n")

            # STEP_4: Compile/link Secure then Normal firmware; never run them.
            app.build()
            elf = workspace / name / "build" / (name + ".elf")
            if not elf.is_file() or elf.stat().st_size == 0:
                raise RuntimeError("Nonempty firmware ELF missing: " + name)
            result["applications"][name] = str(elf)
        result.update(status="PASS", platform=str(xpfm), xsa=str(xsa))
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        (build / "software_build_status.json").write_text(json.dumps(result, indent=2) + "\n")
        vitis.dispose()
    print("SOFTWARE BUILD PASS: " + json.dumps(result["applications"]))


if __name__ == "__main__":
    main()
