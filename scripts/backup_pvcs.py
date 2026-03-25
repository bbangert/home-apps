#!/usr/bin/env python3
"""
Backup Longhorn PVCs to local directory structure: APP_NAME/VOLUME_NAME/CONTENTS

Spins up a temporary pod running rsyncd for each PVC, port-forwards to it,
and uses rsync to copy data out. Rsync is resumable — if it fails or is
interrupted, re-running the script picks up where it left off.

Requires: pip install kubernetes
          rsync (locally installed)
Usage:
    python backup_pvcs.py --output /mnt/backup --node h4uno
    python backup_pvcs.py --output /mnt/backup --node h4uno --dry-run
    python backup_pvcs.py --output /mnt/backup --node h4uno --only immich,plex
    python backup_pvcs.py --output /mnt/backup --node h4uno --skip-scale-down
"""

import argparse
import logging
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from kubernetes import client, config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# PVC registry: app_name -> list of PVC claim names
#
# Shared volumes (media-music, media-video, sabnzbd-downloads) appear under
# the "primary owner" app so they're only backed up once.
# ---------------------------------------------------------------------------

SKIP_PVCS = {
    # Caches / ephemeral — safe to lose
    "immich-machine-learning-cache",
    "plex-cache",
}


@dataclass
class AppVolume:
    """One PVC belonging to an app."""
    app: str
    pvc: str
    namespace: str = "default"
    # If the PVC is RWO and mounted by a workload, we need to scale it down
    # before we can mount it in our temp pod. Set to the deployment/statefulset
    # name. None = try to auto-detect.
    owner_workload: str | None = None
    owner_kind: str = "deployment"  # "deployment" or "statefulset"


# fmt: off
VOLUMES: list[AppVolume] = [
    # ---- Critical user data ----
    AppVolume("immich",           "immich-data"),
    AppVolume("plex",             "plex-config"),
    AppVolume("plex",             "media-music"),
    AppVolume("plex",             "media-video"),
    AppVolume("vaultwarden",      "vaultwarden"),
    AppVolume("ocis",             "ocis-data"),
    AppVolume("komga",            "komga-config"),
    AppVolume("komga",            "komga-assets"),
    AppVolume("calibre-web",      "calibre-web-config"),
    AppVolume("calibre-web",      "media-books"),

    # ---- App config (important, small) ----
    AppVolume("sonarr",           "sonarr-config"),
    AppVolume("radarr",           "radarr-config"),
    AppVolume("lidarr",           "lidarr-config"),
    AppVolume("sabnzbd",          "sabnzbd-config"),
    AppVolume("sabnzbd",          "sabnzbd-downloads"),
    AppVolume("prowlarr",         "prowlarr"),          # volsync-created PVC
    AppVolume("komf",             "komf-config"),
    AppVolume("music-assistant",  "music-assistant-config"),
    AppVolume("duketogo",         "duketogo-config"),
    AppVolume("freshrss",         "freshrss"),
    AppVolume("linkwarden",       "linkwarden"),
    AppVolume("thelounge",        "thelounge"),
    AppVolume("unifi",            "unifi"),
    AppVolume("frigate",          "frigate"),
    AppVolume("frigate",          "frigate-media"),
    AppVolume("atuin",            "atuin"),              # if it has a PVC
    AppVolume("paste",            "paste",    namespace="ofcode"),
    AppVolume("windmill",         "windmill"),           # if it has a PVC

    # ---- Observability (nice to have) ----
    AppVolume("grafana",          "grafana", namespace="observability"),
]
# fmt: on

TEMP_POD_IMAGE = "alpine:3.20"
TEMP_POD_PREFIX = "pvc-backup-"
NAMESPACE_DEFAULT = "default"
POLL_INTERVAL = 2  # seconds
POD_READY_TIMEOUT = 180  # seconds (includes apk install of rsync)
RSYNC_PORT = 873  # rsyncd port inside the pod
RSYNC_RETRIES = 5  # rsync attempts before giving up on a volume
RSYNC_RETRY_DELAY = 5  # seconds between retries


def _find_free_port() -> int:
    """Find a free local port for kubectl port-forward."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Backup k8s PVCs to local directories via rsync")
    p.add_argument("--output", "-o", required=True, help="Base output directory")
    p.add_argument("--dry-run", action="store_true", help="Print plan without executing")
    p.add_argument(
        "--only",
        type=lambda s: set(s.split(",")),
        default=None,
        help="Comma-separated app names to backup (default: all)",
    )
    p.add_argument(
        "--skip",
        type=lambda s: set(s.split(",")),
        default=set(),
        help="Comma-separated PVC names to skip",
    )
    p.add_argument(
        "--skip-scale-down",
        action="store_true",
        help="Don't scale down workloads (use if you've already stopped them)",
    )
    p.add_argument(
        "--node",
        default=None,
        help="Force backup pods onto this node (e.g. --node h4uno). "
             "Useful when the volume's preferred node is down.",
    )
    p.add_argument(
        "--kubeconfig",
        default=None,
        help="Path to kubeconfig (default: use in-cluster or ~/.kube/config)",
    )
    p.add_argument(
        "--retries",
        type=int,
        default=RSYNC_RETRIES,
        help=f"Rsync retry attempts per volume (default: {RSYNC_RETRIES})",
    )
    p.add_argument(
        "--rsync-args",
        default=None,
        help='Extra rsync flags (e.g. --rsync-args="--bwlimit=50000")',
    )
    return p.parse_args()


class PVCBackup:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = Path(args.output)
        self.scaled_down: list[tuple[str, str, str, int]] = []  # (ns, kind, name, replicas)

        if args.kubeconfig:
            config.load_kube_config(config_file=args.kubeconfig)
        else:
            try:
                config.load_incluster_config()
            except config.ConfigException:
                config.load_kube_config()

        self.core = client.CoreV1Api()
        self.apps = client.AppsV1Api()

    def run(self):
        volumes = self._filter_volumes()
        log.info("Will backup %d PVCs across %d apps", len(volumes), len({v.app for v in volumes}))

        if self.args.dry_run:
            self._print_plan(volumes)
            return

        self.output.mkdir(parents=True, exist_ok=True)

        succeeded, failed, skipped = 0, 0, 0
        for vol in volumes:
            try:
                if not self._pvc_exists(vol):
                    log.warning("PVC %s/%s does not exist — skipping", vol.namespace, vol.pvc)
                    skipped += 1
                    continue
                self._backup_one(vol)
                succeeded += 1
            except Exception:
                log.exception("Failed to backup %s/%s", vol.app, vol.pvc)
                failed += 1

        # Restore any scaled-down workloads
        self._restore_scale()

        log.info(
            "Done: %d succeeded, %d failed, %d skipped", succeeded, failed, skipped
        )
        if failed:
            sys.exit(1)

    def _filter_volumes(self) -> list[AppVolume]:
        vols = [v for v in VOLUMES if v.pvc not in SKIP_PVCS]
        if self.args.only:
            vols = [v for v in vols if v.app in self.args.only]
        if self.args.skip:
            vols = [v for v in vols if v.pvc not in self.args.skip]
        return vols

    def _print_plan(self, volumes: list[AppVolume]):
        log.info("=== DRY RUN — no changes will be made ===")
        if self.args.node:
            log.info("Backup pods will be pinned to node: %s", self.args.node)
        current_app = None
        for v in volumes:
            if v.app != current_app:
                current_app = v.app
                print(f"\n  {v.app}/")
            dest = self.output / v.app / v.pvc
            print(f"    {v.pvc}/ -> {dest}")
        print()

    def _pvc_exists(self, vol: AppVolume) -> bool:
        try:
            self.core.read_namespaced_persistent_volume_claim(vol.pvc, vol.namespace)
            return True
        except client.ApiException as e:
            if e.status == 404:
                return False
            raise

    def _find_pods_using_pvc(self, vol: AppVolume) -> list[str]:
        """Find pods currently mounting this PVC."""
        pods = self.core.list_namespaced_pod(vol.namespace).items
        using = []
        for pod in pods:
            if pod.metadata.name.startswith(TEMP_POD_PREFIX):
                continue
            if pod.spec.volumes:
                for v in pod.spec.volumes:
                    if (
                        v.persistent_volume_claim
                        and v.persistent_volume_claim.claim_name == vol.pvc
                    ):
                        using.append(pod.metadata.name)
        return using

    def _find_owner_workload(self, pod_name: str, namespace: str):
        """Walk owner references from a pod to find the deployment/statefulset."""
        pod = self.core.read_namespaced_pod(pod_name, namespace)
        # Pod -> ReplicaSet -> Deployment (typical for Deployments)
        # Pod -> StatefulSet (typical for StatefulSets)
        for ref in pod.metadata.owner_references or []:
            if ref.kind == "StatefulSet":
                return "statefulset", ref.name
            if ref.kind == "ReplicaSet":
                # Look up the ReplicaSet's owner
                rs = self.apps.read_namespaced_replica_set(ref.name, namespace)
                for rs_ref in rs.metadata.owner_references or []:
                    if rs_ref.kind == "Deployment":
                        return "deployment", rs_ref.name
        return None, None

    def _scale_down(self, namespace: str, kind: str, name: str):
        """Scale a workload to 0 and remember original replica count."""
        if kind == "deployment":
            obj = self.apps.read_namespaced_deployment(name, namespace)
            orig = obj.spec.replicas or 1
            if orig == 0:
                return
            log.info("  Scaling down %s/%s from %d to 0", kind, name, orig)
            self.apps.patch_namespaced_deployment_scale(
                name, namespace, {"spec": {"replicas": 0}}
            )
        elif kind == "statefulset":
            obj = self.apps.read_namespaced_stateful_set(name, namespace)
            orig = obj.spec.replicas or 1
            if orig == 0:
                return
            log.info("  Scaling down %s/%s from %d to 0", kind, name, orig)
            self.apps.patch_namespaced_stateful_set_scale(
                name, namespace, {"spec": {"replicas": 0}}
            )
        else:
            return

        self.scaled_down.append((namespace, kind, name, orig))
        self._wait_for_pods_gone(namespace, name)

    def _force_delete_pod(self, pod_name: str, namespace: str):
        """Force-delete a pod (grace_period=0), bypassing kubelet confirmation."""
        try:
            log.warning("  Force-deleting stuck pod %s/%s", namespace, pod_name)
            self.core.delete_namespaced_pod(
                pod_name,
                namespace,
                body=client.V1DeleteOptions(grace_period_seconds=0),
                grace_period_seconds=0,
            )
        except client.ApiException as e:
            if e.status != 404:
                log.error("  Force-delete failed for %s: %s", pod_name, e.reason)

    def _wait_for_pods_gone(
        self,
        namespace: str,
        workload_name: str,
        timeout: int = 60,
        force_timeout: int = 30,
    ):
        """Wait for pods to terminate; force-delete any that get stuck.

        Waits up to `timeout` seconds for graceful termination. Any pods
        still present (typically stuck on a dead node) are force-deleted,
        then we wait another `force_timeout` seconds for the API to clear
        them.
        """
        deadline = time.time() + timeout

        def _find_pods():
            pods = self.core.list_namespaced_pod(
                namespace, label_selector=f"app.kubernetes.io/name={workload_name}"
            ).items
            if not pods:
                pods = self.core.list_namespaced_pod(
                    namespace, label_selector=f"app={workload_name}"
                ).items
            return [
                p for p in pods
                if p.status.phase not in ("Succeeded", "Failed")
            ]

        # Phase 1: wait for graceful shutdown
        while time.time() < deadline:
            remaining = _find_pods()
            if not remaining:
                return
            # Check if any are already stuck in Terminating (deletion_timestamp
            # set but pod still exists — hallmark of a dead node)
            stuck = [
                p for p in remaining
                if p.metadata.deletion_timestamp is not None
            ]
            if stuck and not [p for p in remaining if p.metadata.deletion_timestamp is None]:
                # ALL remaining pods are already Terminating — skip to force
                log.info(
                    "  All %d remaining pod(s) stuck in Terminating — force-deleting",
                    len(stuck),
                )
                break
            time.sleep(POLL_INTERVAL)

        # Phase 2: force-delete anything still hanging around
        remaining = _find_pods()
        if not remaining:
            return

        for pod in remaining:
            self._force_delete_pod(pod.metadata.name, namespace)

        # Phase 3: wait briefly for the API server to clear the objects
        force_deadline = time.time() + force_timeout
        while time.time() < force_deadline:
            remaining = _find_pods()
            if not remaining:
                return
            time.sleep(POLL_INTERVAL)

        still_there = _find_pods()
        if still_there:
            names = [p.metadata.name for p in still_there]
            log.warning(
                "  %d pod(s) still present after force-delete: %s",
                len(names),
                ", ".join(names),
            )

    def _restore_scale(self):
        """Restore all workloads we scaled down."""
        for namespace, kind, name, replicas in reversed(self.scaled_down):
            try:
                log.info("Restoring %s/%s to %d replicas", kind, name, replicas)
                if kind == "deployment":
                    self.apps.patch_namespaced_deployment_scale(
                        name, namespace, {"spec": {"replicas": replicas}}
                    )
                elif kind == "statefulset":
                    self.apps.patch_namespaced_stateful_set_scale(
                        name, namespace, {"spec": {"replicas": replicas}}
                    )
            except Exception:
                log.exception("Failed to restore scale for %s/%s", kind, name)

    def _create_temp_pod(self, vol: AppVolume) -> str:
        """Create a temp pod running rsyncd with the PVC mounted."""
        pod_name = f"{TEMP_POD_PREFIX}{vol.pvc}"[:63]  # k8s name length limit
        if self.args.node:
            log.info("  Pinning backup pod to node %s", self.args.node)

        # Boot script: install rsync, write rsyncd.conf, start daemon
        boot_script = (
            "apk add --no-cache rsync > /dev/null 2>&1 && "
            "printf 'uid = root\\ngid = root\\n"
            "[data]\\npath = /data\\nread only = true\\n"
            "use chroot = no\\nlog file = /dev/stderr\\n' "
            "> /etc/rsyncd.conf && "
            "exec rsync --daemon --no-detach --config=/etc/rsyncd.conf"
        )

        pod_manifest = client.V1Pod(
            metadata=client.V1ObjectMeta(
                name=pod_name,
                namespace=vol.namespace,
                labels={"purpose": "pvc-backup"},
            ),
            spec=client.V1PodSpec(
                restart_policy="Never",
                node_selector=(
                    {"kubernetes.io/hostname": self.args.node}
                    if self.args.node
                    else None
                ),
                tolerations=[
                    client.V1Toleration(operator="Exists"),
                ],
                containers=[
                    client.V1Container(
                        name="rsyncd",
                        image=TEMP_POD_IMAGE,
                        command=["sh", "-c", boot_script],
                        security_context=client.V1SecurityContext(
                            run_as_user=0,
                            run_as_group=0,
                        ),
                        ports=[
                            client.V1ContainerPort(
                                container_port=RSYNC_PORT,
                                name="rsync",
                            )
                        ],
                        volume_mounts=[
                            client.V1VolumeMount(
                                name="data", mount_path="/data", read_only=True
                            )
                        ],
                    )
                ],
                volumes=[
                    client.V1Volume(
                        name="data",
                        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                            claim_name=vol.pvc, read_only=True
                        ),
                    )
                ],
            ),
        )

        # Delete any leftover pod from a previous run (force-delete in case
        # it's stuck on a dead node like talos1)
        try:
            self.core.delete_namespaced_pod(
                pod_name,
                vol.namespace,
                body=client.V1DeleteOptions(grace_period_seconds=0),
                grace_period_seconds=0,
            )
            log.info("  Force-cleaned leftover pod %s", pod_name)
            # Wait for the pod object to actually disappear
            deadline = time.time() + 15
            while time.time() < deadline:
                try:
                    self.core.read_namespaced_pod(pod_name, vol.namespace)
                    time.sleep(POLL_INTERVAL)
                except client.ApiException as gone:
                    if gone.status == 404:
                        break
                    raise
        except client.ApiException as e:
            if e.status != 404:
                raise

        self.core.create_namespaced_pod(vol.namespace, pod_manifest)
        return pod_name

    def _wait_pod_ready(self, pod_name: str, namespace: str):
        """Wait for the pod to be running and rsyncd to be listening."""
        deadline = time.time() + POD_READY_TIMEOUT
        while time.time() < deadline:
            pod = self.core.read_namespaced_pod(pod_name, namespace)
            if pod.status.phase == "Running":
                # Pod is running — verify rsyncd is listening by checking
                # /proc/net/tcp for port 873 (0x0369). Works on bare Alpine
                # without nc/wget/nmap.
                check = subprocess.run(
                    [
                        "kubectl", "exec", pod_name,
                        "-n", namespace, "-c", "rsyncd",
                        "--", "grep", "-q", ":0369", "/proc/net/tcp",
                    ],
                    capture_output=True,
                    timeout=10,
                )
                if check.returncode == 0:
                    return
                # rsyncd not yet listening — apk install probably still running
                time.sleep(POLL_INTERVAL)
                continue
            if pod.status.phase in ("Failed", "Unknown"):
                raise RuntimeError(
                    f"Pod {pod_name} entered {pod.status.phase} state"
                )
            time.sleep(POLL_INTERVAL)
        raise TimeoutError(f"Pod {pod_name} not ready after {POD_READY_TIMEOUT}s")

    def _delete_temp_pod(self, pod_name: str, namespace: str):
        try:
            self.core.delete_namespaced_pod(
                pod_name,
                namespace,
                body=client.V1DeleteOptions(grace_period_seconds=0),
                grace_period_seconds=0,
            )
        except client.ApiException:
            pass

    def _rsync_from_pod(
        self, pod_name: str, namespace: str, dest: Path
    ) -> None:
        """Port-forward to the rsyncd pod and rsync data to local disk.

        Rsync is resumable: if the connection drops, re-running this method
        picks up where it left off (no re-transfer of already-synced files).
        """
        dest.mkdir(parents=True, exist_ok=True)
        local_port = _find_free_port()

        # Start port-forward in the background
        pf_cmd = [
            "kubectl", "port-forward", pod_name,
            f"{local_port}:{RSYNC_PORT}",
            "-n", namespace,
        ]
        log.info("  Port-forwarding localhost:%d -> %s:%d", local_port, pod_name, RSYNC_PORT)
        port_forward = subprocess.Popen(
            pf_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            # Wait for port-forward to be ready
            self._wait_for_port(local_port, timeout=30)

            # Build rsync command
            rsync_cmd = [
                "rsync",
                "-ah",          # archive + human-readable sizes/speeds
                "--partial",    # keep partially transferred files (for resume)
                "--numeric-ids",  # preserve original UIDs/GIDs as numbers
                "--info=progress2",  # single-line progress: % done, speed, ETA
                "--no-inc-recursive",  # scan all files upfront for accurate progress
                f"--port={local_port}",
                f"rsync://127.0.0.1/data/",
                f"{dest}/",
            ]

            if self.args.rsync_args:
                rsync_cmd[1:1] = self.args.rsync_args.split()

            max_attempts = self.args.retries + 1
            for attempt in range(1, max_attempts + 1):
                log.info(
                    "  Rsync attempt %d/%d: %s -> %s",
                    attempt, max_attempts, pod_name, dest,
                )
                # Flush log output so it doesn't interleave with rsync's
                # carriage-return progress line
                for handler in logging.root.handlers:
                    handler.flush()
                sys.stdout.flush()
                sys.stderr.flush()

                result = subprocess.run(rsync_cmd)

                if result.returncode == 0:
                    # Report size
                    total = sum(
                        f.stat().st_size for f in dest.rglob("*") if f.is_file()
                    )
                    log.info("  Synced %s to %s", _human_size(total), dest)
                    return

                # rsync exit codes:
                #   23 = partial transfer (some files couldn't be read) — often OK
                #   24 = vanished files — harmless
                if result.returncode in (23, 24):
                    log.warning(
                        "  Rsync completed with warnings (rc=%d) — treating as success",
                        result.returncode,
                    )
                    return

                if attempt < max_attempts:
                    # Check if port-forward is still alive; restart if needed
                    if port_forward.poll() is not None:
                        log.warning("  Port-forward died — restarting...")
                        port_forward = subprocess.Popen(
                            pf_cmd,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                        )
                        self._wait_for_port(local_port, timeout=30)

                    log.warning(
                        "  Rsync failed (rc=%d) — retrying in %ds "
                        "(rsync will resume where it left off)...",
                        result.returncode,
                        RSYNC_RETRY_DELAY,
                    )
                    time.sleep(RSYNC_RETRY_DELAY)
                else:
                    raise RuntimeError(
                        f"Rsync failed after {max_attempts} attempts for {pod_name} "
                        f"(last rc={result.returncode})"
                    )

        finally:
            # Kill port-forward
            port_forward.terminate()
            try:
                port_forward.wait(timeout=5)
            except subprocess.TimeoutExpired:
                port_forward.kill()

    def _wait_for_port(self, port: int, timeout: int = 30):
        """Wait for a local TCP port to accept connections."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    return
            except OSError:
                time.sleep(0.5)
        raise TimeoutError(f"Port {port} not ready after {timeout}s")

    def _force_delete_pods_using_pvc(self, vol: AppVolume):
        """Force-delete every pod still mounting this PVC.

        This is the nuclear option for pods stuck on a dead node (e.g. talos1).
        The kubelet is gone so graceful deletion never completes — we must
        force-delete (grace_period=0) so the API server releases the PVC.
        """
        stuck = self._find_pods_using_pvc(vol)
        if not stuck:
            return
        log.warning(
            "  %d pod(s) still holding PVC %s after scale-down: %s",
            len(stuck),
            vol.pvc,
            ", ".join(stuck),
        )
        for pod_name in stuck:
            self._force_delete_pod(pod_name, vol.namespace)

        # Wait for the API server to actually remove the pod objects
        deadline = time.time() + 30
        while time.time() < deadline:
            remaining = self._find_pods_using_pvc(vol)
            if not remaining:
                log.info("  All stuck pods cleared for PVC %s", vol.pvc)
                return
            time.sleep(POLL_INTERVAL)

        still = self._find_pods_using_pvc(vol)
        if still:
            log.warning(
                "  %d pod(s) STILL present after force-delete — PVC may "
                "fail to mount: %s",
                len(still),
                ", ".join(still),
            )

    def _backup_one(self, vol: AppVolume):
        dest = self.output / vol.app / vol.pvc
        log.info("Backing up %s/%s -> %s", vol.app, vol.pvc, dest)

        # --- Scale down pods using this PVC (for RWO volumes) ---
        if not self.args.skip_scale_down:
            using_pods = self._find_pods_using_pvc(vol)
            if using_pods:
                log.info("  PVC in use by: %s", ", ".join(using_pods))
                for pod_name in using_pods:
                    kind, name = self._find_owner_workload(pod_name, vol.namespace)
                    if kind and name:
                        already = any(
                            n == name and ns == vol.namespace
                            for ns, _, n, _ in self.scaled_down
                        )
                        if not already:
                            self._scale_down(vol.namespace, kind, name)
                    else:
                        # Orphan pod or owner on a dead node — force-delete it
                        # directly since there's no workload to scale down
                        log.warning(
                            "  No owner workload for pod %s — force-deleting",
                            pod_name,
                        )
                        self._force_delete_pod(pod_name, vol.namespace)

                # After scale-down, re-check: any pods still clinging to the
                # PVC are stuck (typically on the dead talos1 node). Force-
                # delete them so the temp backup pod can mount the volume.
                self._force_delete_pods_using_pvc(vol)

        # --- Create temp pod ---
        pod_name = self._create_temp_pod(vol)
        try:
            log.info("  Waiting for pod %s (installing rsync + starting daemon)...", pod_name)
            self._wait_pod_ready(pod_name, vol.namespace)

            # --- Rsync data out ---
            self._rsync_from_pod(pod_name, vol.namespace, dest)

            log.info("  ✓ %s/%s backed up", vol.app, vol.pvc)

        finally:
            self._delete_temp_pod(pod_name, vol.namespace)


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


if __name__ == "__main__":
    args = parse_args()
    PVCBackup(args).run()