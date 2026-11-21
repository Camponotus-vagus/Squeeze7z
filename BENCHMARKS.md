# Benchmarks

Two runs on a MacBook Air M5 (10 cores, 32 GB), November 2026, with the command-line tool and the bundled 7-Zip 26.06. The reference is `7zz a -t7z -mx9 -snl`, run on the same unpacked files; Keka at its maximum setting gives practically the same bytes. One run each on a machine in normal use, so times are rough.

Every Squeeze7z output was extracted with `7zz` and compared with the source tree (`diff -r`). All were identical.

## Run 1: size, 13 inputs

Smart and Best against `-mx9` on three public corpora and ten real archives of the author's (described by content only, not published).

| Input | `7zz -mx9` bytes | Smart | Best | Time: mx9 / Smart / Best |
|---|---|---|---|---|
| Canterbury + large corpus, 14 MB | 3,030,976 | -9.38% | -11.74% | 2.0 / 4.7 / 17.6 s |
| C headers of the macOS SDK, 33 MB | 3,189,279 | -7.61% | -7.71% | 3.2 / 6.6 / 28.0 s |
| Silesia corpus, 212 MB | 48,688,242 | -4.70% | -5.99% | 30.5 / 53.7 / 163.4 s |
| JPEG photos, 128 MB | 127,118,539 | 0.00% | 0.00% | 5.1 / 7.1 / 18.8 s |
| Python project with a git pack, 320 MB | 175,508,946 | -1.77% | -1.77% | 13.2 / 20.7 / 183.6 s |
| Python project with a git pack, 97 MB | 87,729,126 | 0.00% | 0.00% | 3.5 / 5.0 / 58.9 s |
| C++ source with images, 82 MB | 71,726,251 | -0.42% | -0.64% | 13.5 / 27.2 / 102.6 s |
| EXR depth maps, 69 MB | 66,829,061 | 0.00% | 0.00% | 1.9 / 18.9 / 16.8 s |
| 3D model, 34 MB | 32,394,031 | 0.00% | 0.00% | 1.3 / 5.6 / 10.7 s |
| JPEG gallery, 52 MB | 50,189,722 | 0.00% | -0.04% | 1.8 / 4.2 / 7.7 s |
| arm64 macOS app, 4 MB | 2,298,649 | 0.00% | 0.00% | 0.4 / 1.4 / 3.1 s |
| Python source tree, 3 MB packed | 2,165,562 | -11.96% | -12.43% | 2.0 / 5.4 / 11.4 s |
| Point clouds, 3 MB | 2,229,495 | 0.00% | -2.12% | 0.1 / 1.1 / 1.5 s |
| **Total bytes** | | **-0.96%** | **-1.10%** | 78 / 162 / 624 s |

Smart was never larger than `-mx9`. Best was 0.14% smaller than Smart in total and took four times as long. The time of EXR on Smart (18.9 s) was noise from machine load; another run of the same layout took 3.0 s.

These times predate the parallel media block and the side-by-side Smart builds of run 2. Raw data: [docs/bench-data/smart.csv](docs/bench-data/smart.csv).

## Run 2: speed, 5 public inputs

After a user saw Squeeze7z use under 100% of the CPU on a folder of photos, two changes went in. Already compressed files (jpg, heic, mp4, mov, zip and similar, 64 MB or more in total) now go in their own block of independent LZMA2 chunks, one per pair of cores. And Smart builds its two candidate archives at the same time. "Before" is the build without those changes, run with the same 7zz.

Inputs: the Canterbury corpus (2.7 MB) and Silesia (202 MB) as folders, the C headers of the macOS 26 SDK (90 MB), the wallpapers shipped with macOS 26 (623 MB: 15 HEIC, 5 MOV, 1 JPEG), and a mixed folder (174 MB: seven of those wallpapers, the Foundation, AppKit and CoreFoundation headers, and a copy of Calculator.app). All can be rebuilt on any Mac with `scripts/bench/parallel_run.py`.

| Input | `7zz -mx9` | Smart before | Smart now | Fast now | Time: mx9 / Smart before / Smart now / Fast now |
|---|---|---|---|---|---|
| Canterbury | 483,895 | 424,596 | 424,596 | 483,895 | 0.2 / 0.7 / 0.5 / 0.3 s |
| SDK headers | 8,137,992 | 7,468,507 | 7,468,507 | 8,137,992 | 10.6 / 20.0 / 16.6 / 13.2 s |
| Silesia | 48,688,242 | 46,399,135 | 46,399,135 | 48,688,242 | 31.6 / 57.2 / 41.2 / 33.7 s |
| Mixed folder | 172,337,034 | 172,337,034 | 172,169,569 | 172,341,476 | 5.9 / 6.2 / 3.5 / 3.0 s |
| Wallpapers | 652,185,884 | 652,179,190 | 652,189,117 | 652,189,117 | 12.7 / 34.3 / 9.6 / 9.8 s |
| **Total time** | | | | | **61.0 / 118.4 / 71.4 / 60.0 s** |

On text the sizes did not change and Smart got 17 to 28% faster. On the wallpapers it went from 34.3 s to 9.6 s, faster than `-mx9`, for an archive 3.2 KB (0.0005%) larger than `-mx9`. On the mixed folder Smart is now also smaller than `-mx9`: once the photos are set aside, the headers are most of what is left, enough for the PPMd text block. The mixed output was also extracted with bsdtar (libarchive) and was identical.

Raw data: [docs/bench-data/parallel.csv](docs/bench-data/parallel.csv).

## Limits

- Fast and Smart can now be a few KB larger than `-mx9` on photos and videos. On one user's folder of JPEGs the saving went from 3.3% to 3.0%. Chunks cannot refer to each other, so near-identical photos stored in different chunks lose the match. The setting "Compress photos, videos and zips on all cores", or `--single-stream` on the command line, goes back to a single stream.
- Times come from single runs on one machine. They show the order of magnitude, not a precise ratio.
- Only names, sizes, contents and links of the extracted files were compared. Dates, permissions and extended attributes were not.
