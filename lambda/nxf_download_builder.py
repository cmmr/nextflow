"""
nxf_download_builder.py - Package one run's published results as a single zip.

Author: Daniel Smith
Date:   August 26th, 2026

Invoked asynchronously by nxf_download with {"uid": "<uid>"}. Streams every
object under $S3_RUN_PREFIX/<uid>/ into a zip written straight to
$S3_ZIP_PREFIX/<uid>.zip as an S3 multipart upload: nothing reaches disk, and
only the read-ahead and the parts in flight are held in memory, so a run far
larger than the function is packaged in one pass.

The zip keeps the published layout under one directory, so unpacking it and
opening index.html gives the same dashboard offline.

Objects that are already compressed are stored rather than deflated - the reads
and most of the artifacts arrive gzipped, and deflating them again would spend
the time budget for nothing.

Progress goes to $S3_ZIP_PREFIX/<uid>.json every couple of seconds, which is
what the waiting page polls. A failure is recorded there rather than raised, so
the reader is told what went wrong instead of watching a bar that never moves.

Env: AWS_S3_BUCKET, S3_RUN_PREFIX, S3_ZIP_PREFIX, MAX_TOTAL_BYTES,
     PART_SIZE_BYTES, READ_AHEAD_BYTES, UPLOAD_THREADS, DEFLATE_LEVEL
"""

import html
import json
import os
import queue
import re
import threading
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

MEGABYTE = 1024 * 1024

BUCKET = os.environ["AWS_S3_BUCKET"]
RUN_PREFIX = os.environ.get("S3_RUN_PREFIX", "nxf").strip("/")
ZIP_PREFIX = os.environ.get("S3_ZIP_PREFIX", "zip").strip("/")

# Refuse a run this pass could not finish inside Lambda's 15 minutes rather than
# spend the time finding out
MAX_TOTAL_BYTES = int(os.environ.get("MAX_TOTAL_BYTES", str(100 * 1024 * MEGABYTE)))

PART_SIZE = int(os.environ.get("PART_SIZE_BYTES", str(16 * MEGABYTE)))
READ_AHEAD = int(os.environ.get("READ_AHEAD_BYTES", str(128 * MEGABYTE)))
UPLOAD_THREADS = int(os.environ.get("UPLOAD_THREADS", "4"))
DEFLATE_LEVEL = int(os.environ.get("DEFLATE_LEVEL", "1"))

CHUNK_SIZE = MEGABYTE

# S3 takes 10,000 parts; the margin covers the zip's own headers
MAX_PARTS = 9000

# Entries at or above this are written with zip64 headers. Well under the 4 GB
# the format needs them at, since a streamed entry's size is only claimed.
ZIP64_LIMIT = 2 ** 31

REPORT_SECONDS = 2

# Stop with time left to abort the upload and record why
TIME_MARGIN_SECONDS = 45

# Compressing these again costs the time budget and saves nothing
STORED_EXTENSIONS = frozenset(
    """gz bgz tgz zip bz2 xz zst 7z rar qza qzv bam cram bai crai biom h5 hdf5
       parquet rds rda npz jpg jpeg png gif webp pdf mp4 woff woff2""".split()
)

s3 = boto3.client("s3", config=Config(max_pool_connections=UPLOAD_THREADS + 4))


class DownloadError(Exception):
    """A failure whose message is written for the reader waiting on the page.
    Anything else that goes wrong is logged and reported in general terms."""


def zip_key(uid):
    return f"{ZIP_PREFIX}/{uid}.zip"


def state_key(uid):
    return f"{ZIP_PREFIX}/{uid}.json"


def report(uid, state):
    """Write the progress file the waiting page polls."""
    state["updated"] = time.time()

    s3.put_object(
        Bucket=BUCKET,
        Key=state_key(uid),
        Body=json.dumps(state).encode(),
        ContentType="application/json",
        CacheControl="no-store",
    )


def folder_name(uid):
    """What the reader knows this run as - the task name off the dashboard -
    which names both the zip and the one directory inside it."""
    try:
        head = s3.get_object(
            Bucket=BUCKET, Key=f"{RUN_PREFIX}/{uid}/index.html", Range="bytes=0-4095"
        )["Body"].read()
    except ClientError:
        return uid

    found = re.search(r"<title>(.*?)</title>", head.decode("utf-8", "replace"), re.S | re.I)

    if not found:
        return uid

    # The zip is unpacked on whatever the reader runs, so the name is cut back to
    # what every filesystem takes
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", html.unescape(found.group(1))).strip("-._")[:60]

    return f"{name}-{uid}" if name else uid


def list_entries(prefix):
    """Every object published under the run's prefix, in key order."""
    entries = []
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix)

    for page in pages:
        for item in page.get("Contents", []):
            if not item["Key"].endswith("/"):
                entries.append(item)

    entries.sort(key=lambda item: item["Key"])

    return entries


def part_size_for(total):
    """Big enough that the whole zip fits in the parts S3 allows."""
    needed = -(-total // MAX_PARTS)

    return max(PART_SIZE, -(-needed // MEGABYTE) * MEGABYTE)


def compression_for(name):
    extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""

    if extension in STORED_EXTENSIONS:
        return zipfile.ZIP_STORED

    return zipfile.ZIP_DEFLATED


class MultipartWriter:
    """A write-only, non-seekable sink that uploads what is written to it as the
    parts of one S3 multipart upload.

    zipfile finds no seek() here and so writes each entry with a trailing data
    descriptor, which is what lets an entry be written before its size and CRC
    are known.
    """

    def __init__(self, key, part_size, threads, metadata):
        self.key = key
        self.part_size = part_size
        self.max_pending = threads * 2
        self.buffer = bytearray()
        self.position = 0
        self.number = 0
        self.aborted = False
        self.pending = []
        self.parts = []
        self.pool = ThreadPoolExecutor(max_workers=threads)
        self.upload_id = s3.create_multipart_upload(
            Bucket=BUCKET, Key=key, ContentType="application/zip", Metadata=metadata
        )["UploadId"]

    def writable(self):
        return True

    def seekable(self):
        return False

    def tell(self):
        return self.position

    def flush(self):
        pass

    def write(self, data):
        # Swallowed once the upload is gone, so that closing the archive on the
        # way out cannot address parts of it
        if self.aborted:
            return len(data)

        self.buffer += data
        self.position += len(data)

        while len(self.buffer) >= self.part_size:
            self.send(bytes(self.buffer[: self.part_size]))
            del self.buffer[: self.part_size]

        return len(data)

    def send(self, chunk):
        while len(self.pending) >= self.max_pending:
            self.collect()

        self.number += 1

        self.pending.append(
            (
                self.number,
                self.pool.submit(
                    s3.upload_part,
                    Bucket=BUCKET,
                    Key=self.key,
                    UploadId=self.upload_id,
                    PartNumber=self.number,
                    Body=chunk,
                ),
            )
        )

    def collect(self):
        number, future = self.pending.pop(0)
        self.parts.append({"PartNumber": number, "ETag": future.result()["ETag"]})

    def close(self):
        """Send what is left - only the last part may be under S3's 5 MB floor -
        and turn the parts into the object."""
        if self.buffer:
            self.send(bytes(self.buffer))
            self.buffer.clear()

        while self.pending:
            self.collect()

        self.pool.shutdown()
        self.parts.sort(key=lambda part: part["PartNumber"])

        s3.complete_multipart_upload(
            Bucket=BUCKET,
            Key=self.key,
            UploadId=self.upload_id,
            MultipartUpload={"Parts": self.parts},
        )

    def abort(self):
        self.aborted = True
        self.pool.shutdown(wait=False, cancel_futures=True)
        s3.abort_multipart_upload(Bucket=BUCKET, Key=self.key, UploadId=self.upload_id)


def offer(chunks, item, stop):
    """Queue one item, giving up if the build has been abandoned."""
    while not stop.is_set():
        try:
            chunks.put(item, timeout=1)
            return True
        except queue.Full:
            continue

    return False


def read_objects(entries, chunks, stop):
    """Fetch each object in the order the zip takes them, so the next one is
    being read while the last part is still uploading."""
    try:
        for entry in entries:
            if not offer(chunks, ("start", entry), stop):
                return

            body = s3.get_object(Bucket=BUCKET, Key=entry["Key"])["Body"]

            while True:
                chunk = body.read(CHUNK_SIZE)

                if not chunk:
                    break

                if not offer(chunks, ("data", chunk), stop):
                    body.close()
                    return

            body.close()

            if not offer(chunks, ("end", entry), stop):
                return
    except Exception as error:
        offer(chunks, ("error", error), stop)
        return

    offer(chunks, ("done", None), stop)


def zip_entry(root, prefix, entry, level):
    name = root + "/" + entry["Key"][len(prefix):]

    info = zipfile.ZipInfo(name, date_time=entry["LastModified"].timetuple()[:6])
    info.compress_type = compression_for(name)
    info.file_size = entry["Size"]
    info.external_attr = 0o644 << 16

    # zipfile reads the level off the entry, not off the archive, whenever the
    # entry is one it was handed
    info._compresslevel = level

    return info


def build(uid, deadline):
    prefix = f"{RUN_PREFIX}/{uid}/"
    entries = list_entries(prefix)

    if not entries:
        raise DownloadError("There is nothing published for this run to package.")

    total = sum(entry["Size"] for entry in entries)
    gigabyte = 1024 * MEGABYTE

    if total > MAX_TOTAL_BYTES:
        raise DownloadError(
            f"These results come to {total / gigabyte:.1f} GB, and this download"
            f" packages up to {MAX_TOTAL_BYTES / gigabyte:.0f} GB in one go. Use the"
            " individual download links on the results page instead."
        )

    root = folder_name(uid)
    state = {
        "state": "building",
        "files_total": len(entries),
        "files_done": 0,
        "bytes_total": total,
        "bytes_done": 0,
    }
    report(uid, state)

    chunks = queue.Queue(maxsize=max(8, READ_AHEAD // CHUNK_SIZE))
    stop = threading.Event()
    reader = threading.Thread(target=read_objects, args=(entries, chunks, stop), daemon=True)
    reader.start()

    writer = MultipartWriter(zip_key(uid), part_size_for(total), UPLOAD_THREADS, {"folder": root})
    archive = zipfile.ZipFile(writer, "w", allowZip64=True)
    destination = None
    announced = 0.0

    try:
        while True:
            kind, payload = chunks.get()

            if kind == "start":
                destination = archive.open(
                    zip_entry(root, prefix, payload, DEFLATE_LEVEL),
                    "w",
                    force_zip64=payload["Size"] >= ZIP64_LIMIT,
                )
            elif kind == "data":
                destination.write(payload)
                state["bytes_done"] += len(payload)

                if time.monotonic() - announced >= REPORT_SECONDS:
                    announced = time.monotonic()
                    report(uid, state)
            elif kind == "end":
                destination.close()
                destination = None
                state["files_done"] += 1
            elif kind == "error":
                raise payload
            else:
                break

            if time.monotonic() > deadline:
                raise DownloadError(
                    "Packaging these results took longer than the download job is"
                    " allowed to run. Use the individual download links on the"
                    " results page instead."
                )

        archive.close()
        writer.close()
    except BaseException:
        stop.set()
        writer.abort()

        if destination is not None:
            try:
                destination.close()
            except Exception:
                pass

        raise

    s3.delete_object(Bucket=BUCKET, Key=state_key(uid))


def lambda_handler(event, context):
    uid = event["uid"]

    if not re.match(r"^[a-z2-7]{8}$", uid):
        raise ValueError(f"Not a run id: {uid!r}")

    deadline = time.monotonic() + context.get_remaining_time_in_millis() / 1000 - TIME_MARGIN_SECONDS

    try:
        build(uid, deadline)
    except Exception as error:
        # Recorded rather than raised: the waiting page has to be able to say
        # what went wrong, and a raise would only be retried to the same end.
        print(f"Packaging {uid} failed: {error!r}")

        if isinstance(error, DownloadError):
            message = str(error)
        else:
            message = (
                "Something went wrong while packaging these results. Tell your CMMR"
                f" contact, quoting run {uid}."
            )

        report(uid, {"state": "failed", "error": message})

        return {"uid": uid, "state": "failed"}

    return {"uid": uid, "state": "ready"}
