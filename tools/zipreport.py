#!/usr/bin/env python3
"""Report on a downloaded export archive.

Replaces a hand-rolled ZIP central-directory parser that ran in the browser via
fetch(). That could not work here: Main.ACT_PDF_ExportZip ends in a Download file
action with showFileInBrowser=false, so the browser converts the iframe
navigation into a DOWNLOAD -- the iframe's location never changes, no URL is
observable from the page, and the guid stops resolving moments later. The bytes
are captured from the browser's own network log instead, and read here.

Modes
  names    one archive entry name per line
  pdf      "<name>~~OK <bytes>" or "<name>~~BAD <reason>" -- opens each entry
  records  "<name>~~<crc32>~~<bytes>" -- content identity, no inflation needed
"""
import sys, zipfile

def main():
    if len(sys.argv) < 3:
        print("usage: zipreport.py <zipfile> <names|pdf|records>", file=sys.stderr)
        return 2
    path, mode = sys.argv[1], sys.argv[2]
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        print("ERR not a zip: %s" % e, file=sys.stderr)
        return 1
    except OSError as e:
        print("ERR cannot open: %s" % e, file=sys.stderr)
        return 1

    infos = [i for i in zf.infolist() if not i.is_dir()]
    if not infos:
        print("ERR archive holds no files", file=sys.stderr)
        return 1

    for i in infos:
        if mode == "names":
            print(i.filename)
        elif mode == "records":
            print("%s~~%08x~~%d" % (i.filename, i.CRC, i.file_size))
        elif mode == "pdf":
            # Actually open it. Correct names and distinct CRCs would still pass
            # if the export wrote an error page or an HTML login redirect.
            try:
                head = zf.open(i).read(5)
            except Exception as e:
                print("%s~~BAD unreadable (%s)" % (i.filename, e))
                continue
            if i.file_size == 0:
                print("%s~~BAD empty" % i.filename)
            elif head[:4] != b"%PDF":
                print("%s~~BAD not a PDF (starts %r)" % (i.filename, head[:5]))
            else:
                print("%s~~OK %d" % (i.filename, i.file_size))
        else:
            print("ERR unknown mode %s" % mode, file=sys.stderr)
            return 2
    return 0

sys.exit(main())
