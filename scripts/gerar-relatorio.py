from pathlib import Path
from re import sub
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import PageBreak, Paragraph, Preformatted, SimpleDocTemplate, Spacer, Table, TableStyle


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "RELATORIO_FASE5.md"
TARGET = ROOT / "RELATORIO_FASE5.pdf"


def markup(value: str) -> str:
    value = escape(value.strip())
    value = sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", value)
    value = sub(r"`(.+?)`", r"<font name='Courier'>\1</font>", value)
    value = sub(r"\[(.+?)\]\((.+?)\)", r"<link href='\2'>\1</link>", value)
    return value


styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name="TitleST", parent=styles["Title"], fontName="Helvetica-Bold", fontSize=23, leading=28, textColor=colors.HexColor("#12355b"), alignment=TA_CENTER, spaceAfter=14))
styles.add(ParagraphStyle(name="H2ST", parent=styles["Heading2"], fontName="Helvetica-Bold", fontSize=15, leading=18, textColor=colors.HexColor("#176b87"), spaceBefore=12, spaceAfter=7, keepWithNext=True))
styles.add(ParagraphStyle(name="H3ST", parent=styles["Heading3"], fontName="Helvetica-Bold", fontSize=11.5, leading=14, textColor=colors.HexColor("#176b87"), spaceBefore=9, spaceAfter=5, keepWithNext=True))
styles.add(ParagraphStyle(name="BodyST", parent=styles["BodyText"], fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=colors.HexColor("#172033"), spaceAfter=5))
styles.add(ParagraphStyle(name="BulletST", parent=styles["BodyST"], leftIndent=12, firstLineIndent=-7, bulletIndent=3))
styles.add(ParagraphStyle(name="TableST", parent=styles["BodyST"], fontSize=7.7, leading=9.5, spaceAfter=0))

lines = SOURCE.read_text(encoding="utf-8").splitlines()
story = []
i = 0
in_code = False
code_lines = []
while i < len(lines):
    line = lines[i]
    if line.startswith("```"):
        if in_code:
            story.append(Preformatted("\n".join(code_lines), ParagraphStyle(name=f"Code{i}", parent=styles["Code"], fontName="Courier", fontSize=7.2, leading=9, backColor=colors.HexColor("#f3f5f7"), borderPadding=5, spaceAfter=6)))
            code_lines = []
        in_code = not in_code
        i += 1
        continue
    if in_code:
        code_lines.append(line)
        i += 1
        continue
    if line.startswith("| ") and i + 1 < len(lines) and lines[i + 1].startswith("|---"):
        rows = []
        while i < len(lines) and lines[i].startswith("|"):
            cells = [cell.strip() for cell in lines[i].strip("|").split("|")]
            if not all(set(cell) <= {"-", ":"} for cell in cells):
                rows.append([Paragraph(markup(cell), styles["TableST"]) for cell in cells])
            i += 1
        widths = [(A4[0] - 37 * mm) / len(rows[0])] * len(rows[0])
        table = Table(rows, colWidths=widths, repeatRows=1, hAlign="LEFT")
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e7f1f5")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#12355b")),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#b7c4cf")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 4),
            ("RIGHTPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING", (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ]))
        story.extend([table, Spacer(1, 5)])
        continue
    if line.startswith("# "):
        if story:
            story.append(PageBreak())
        story.append(Paragraph(markup(line[2:]), styles["TitleST"]))
    elif line.startswith("## "):
        story.append(Paragraph(markup(line[3:]), styles["H2ST"]))
    elif line.startswith("### "):
        story.append(Paragraph(markup(line[4:]), styles["H3ST"]))
    elif line.startswith("- "):
        story.append(Paragraph("• " + markup(line[2:]), styles["BulletST"]))
    elif line.strip():
        story.append(Paragraph(markup(line), styles["BodyST"]))
    else:
        story.append(Spacer(1, 3))
    i += 1


def footer(canvas, document):
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.HexColor("#667788"))
    canvas.drawRightString(A4[0] - 17 * mm, 10 * mm, f"Página {document.page}")
    canvas.restoreState()


document = SimpleDocTemplate(str(TARGET), pagesize=A4, rightMargin=17 * mm, leftMargin=20 * mm, topMargin=18 * mm, bottomMargin=18 * mm, title="SolidaryTech — Hackathon DCLT — Fase 5", author="Philipe de Oliveira Marchezini")
document.build(story, onFirstPage=footer, onLaterPages=footer)
print(f"Relatório gerado: {TARGET}")
