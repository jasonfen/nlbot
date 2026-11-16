# Launch memorious-mcp with timestamps in local time (${TIMEZONE}) instead
# of UTC, and with exact-key store/forget (see the second patch below).
# Run by run-memorious.sh.
#
# Why: memorious-mcp 0.0.2 hardcodes `datetime.now(timezone.utc)` in
# backends/chroma_backend.py, so anything stored after 20:00 in a UTC-4 zone is stamped with
# tomorrow's date. That made the vault's dates disagree with ${HUMAN_NAME}'s clock
# (noticed 2026-09-10). Journals, job-log and git already use local time.
#
# Why a launch-time patch and not an edit to the package: uvx caches the package
# in ~/.cache/uv/archive-v0/<hash>/ and can re-resolve it into a new directory on
# any launch, which would silently throw away an in-place edit.
#
# The stored value is still ISO-8601 with an explicit offset
# (2026-09-10T22:40:00-04:00), so it is an unambiguous instant, the same as
# before. Only the displayed date and time change.
#
# If the package ever stops importing `datetime` into chroma_backend, the patch
# prints a warning to stderr and memorious runs unpatched (UTC). It degrades
# rather than failing to start, because a crashed memorious means no recall/store
# tools for the whole session.
import sys
from datetime import datetime as _datetime

try:
    import memorious_mcp.backends.chroma_backend as _cb

    if getattr(_cb, "datetime", None) is not _datetime:
        raise AttributeError("chroma_backend.datetime is not datetime.datetime")

    class _LocalDatetime(_datetime):
        @classmethod
        def now(cls, tz=None):
            # Ignore the tz argument (the package passes timezone.utc) and
            # return local time with its offset attached.
            return _datetime.now().astimezone()

    _cb.datetime = _LocalDatetime
except Exception as e:  # noqa: BLE001 - never block startup over a cosmetic patch
    print(f"memorious-localtime: patch NOT applied ({e}); timestamps stay UTC",
          file=sys.stderr)


# --- Exact-key store and forget (2026-11-15) -------------------------------
# memorious-mcp 0.0.2 has two traps that work together:
#  * store() calls collection.add(), which silently ignores an id that already
#    exists, so a correction needed forget-then-store.
#  * forget() deletes the top_k (default 3) NEAREST entries by embedding, with
#    no distance cutoff. Every forget took two unrelated neighbours with it
#    (seen twice on the source system).
# Patched: store upserts (same key = overwrite), and forget deletes only the
# exact key, returning [] if it doesn't exist. Semantic "forget everything
# about X" is gone on purpose: recall, then forget each key you mean.
# Same degrade rule as above: if the backend has changed shape, warn and run
# unpatched rather than fail to start.
try:
    from datetime import timezone as _tz
    from memorious_mcp.backends.chroma_backend import ChromaMemoryBackend as _CMB

    if "add" not in _CMB.store.__code__.co_names or "recall" not in _CMB.forget.__code__.co_names:
        raise AttributeError("ChromaMemoryBackend.store/forget no longer look like 0.0.2")

    def _store(self, key, value, metadata=None):
        _id = str(key)
        meta = dict(metadata) if metadata else {}
        meta["key"] = key
        meta["value"] = value
        meta["timestamp"] = _cb.datetime.now(_tz.utc).isoformat()
        self.collection.upsert(ids=[_id], documents=[key], metadatas=[meta])
        return _id

    def _forget(self, key, top_k=3):  # top_k kept for the tool signature; unused
        ids = self.collection.get(ids=[str(key)]).get("ids") or []
        if ids:
            self.collection.delete(ids=ids)
        return list(ids)

    _CMB.store = _store
    _CMB.forget = _forget
except Exception as e:  # noqa: BLE001
    print(f"memorious-localtime: exact-key patch NOT applied ({e}); "
          "forget still deletes neighbours", file=sys.stderr)


def _localize_existing(path="./.memorious", collection="memories"):
    """Rewrite any UTC (+00:00) timestamps already in the store to local time.

    Idempotent: after the first pass no +00:00 stamps remain, so later starts
    change nothing. Runs here at startup, before main() opens the database,
    because this is the one moment no other memorious process holds the store.
    Chroma's PersistentClient isn't safe to write from two processes. Only the
    timestamp field changes; documents aren't passed, so nothing is re-embedded.
    Backup of the pre-migration store: .memorious.bak-2026-09-10/.
    """
    try:
        import chromadb
        col = chromadb.PersistentClient(path=path).get_collection(collection)
        got = col.get(include=["metadatas"])
        ids, metas = [], []
        for _id, md in zip(got["ids"], got["metadatas"]):
            ts = (md or {}).get("timestamp")
            if isinstance(ts, str) and ts.endswith("+00:00"):
                md = dict(md)
                md["timestamp"] = _datetime.fromisoformat(ts).astimezone().isoformat()
                ids.append(_id)
                metas.append(md)
        if ids:
            col.update(ids=ids, metadatas=metas)
            print(f"memorious-localtime: localized {len(ids)} UTC timestamps",
                  file=sys.stderr)
    except Exception as e:  # noqa: BLE001 - same rule: never block startup
        print(f"memorious-localtime: localize pass skipped ({e})", file=sys.stderr)


if __name__ == "__main__":
    _localize_existing()

from memorious_mcp.main import main  # noqa: E402

sys.exit(main())
