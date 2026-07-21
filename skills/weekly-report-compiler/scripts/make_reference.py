#!/usr/bin/env python3
"""
Generates scripts/reference.docx with Lexend as the default font.
Run once during setup after installing the Lexend font.
"""

import subprocess
import sys
from pathlib import Path


FONT_NAME = "Lexend"
OUTPUT_PATH = Path(__file__).parent / "reference.docx"


def check_lexend_installed() -> bool:
    result = subprocess.run(["fc-list"], capture_output=True, text=True)
    return FONT_NAME.lower() in result.stdout.lower()


def set_font_on_style(style, font_name: str) -> None:
    from docx.oxml.ns import qn
    from docx.oxml import OxmlElement
    rPr = style.element.get_or_add_rPr()
    rFonts = rPr.find(qn("w:rFonts"))
    if rFonts is None:
        rFonts = OxmlElement("w:rFonts")
        rPr.insert(0, rFonts)
    for attr in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rFonts.set(qn(attr), font_name)


def main() -> None:
    if not check_lexend_installed():
        print(
            f"Error: {FONT_NAME} font not found.\n"
            "Install with:\n"
            "  sudo apt-get install fonts-lexend\n"
            "  Then run: fc-cache -fv\n"
            "  Then re-run: python3 scripts/make_reference.py",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        from docx import Document
        from docx.shared import Pt
    except ImportError:
        print("Error: python-docx not installed. Run: pip install python-docx", file=sys.stderr)
        sys.exit(1)

    doc = Document()

    target_styles = ["Normal", "Heading 1", "Heading 2", "Heading 3", "Default Paragraph Font"]
    for style_name in target_styles:
        try:
            style = doc.styles[style_name]
            style.font.name = FONT_NAME
            set_font_on_style(style, FONT_NAME)
        except KeyError:
            pass

    doc.styles["Normal"].font.size = Pt(11)

    doc.save(OUTPUT_PATH)
    print(f"Created: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
