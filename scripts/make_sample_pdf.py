#!/usr/bin/env python3
"""Builds a small book-like PDF for testing the converter.

It has the things that make real book PDFs awkward to reflow: a picture
cover, running heads that change per chapter, page numbers, justified and
hyphenated text with first-line indents, italics, a scene break, an
illustration plate and PDF bookmarks.

    pip install reportlab pyphen
    python3 scripts/make_sample_pdf.py Tests/Fixtures/alice-sample.pdf
    python3 scripts/make_sample_pdf.py --no-bookmarks Tests/Fixtures/alice-no-bookmarks.pdf
"""
import argparse
import io

from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
from reportlab.lib.pagesizes import A5
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.platypus import (BaseDocTemplate, Frame, Image, NextPageTemplate, PageBreak,
                                PageTemplate, Paragraph, Spacer)

TITLE = "Alice’s Adventures in Wonderland"
AUTHOR = "Lewis Carroll"

CHAPTERS = [
    ("CHAPTER I.", "Down the Rabbit-Hole", [
        "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”",
        "So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.",
        "There was nothing so <i>very</i> remarkable in that; nor did Alice think it so <i>very</i> much out of the way to hear the Rabbit say to itself, “Oh dear! Oh dear! I shall be late!” (when she thought it over afterwards, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural); but when the Rabbit actually <i>took a watch out of its waistcoat-pocket</i>, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge.",
        "In another moment down went Alice after it, never once considering how in the world she was to get out again.",
        "The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.",
        "Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs. She took down a jar from one of the shelves as she passed; it was labelled “ORANGE MARMALADE”, but to her great disappointment it was empty: she did not like to drop the jar for fear of killing somebody underneath, so managed to put it into one of the cupboards as she fell past it.",
        "“Well!” thought Alice to herself, “after such a fall as this, I shall think nothing of tumbling down stairs! How brave they’ll all think me at home! Why, I wouldn’t say anything about it, even if I fell off the top of the house!” (Which was very likely true.)",
        "Down, down, down. Would the fall <i>never</i> come to an end? “I wonder how many miles I’ve fallen by this time?” she said aloud. “I must be getting somewhere near the centre of the earth. Let me see: that would be four thousand miles down, I think—” (for, you see, Alice had learnt several things of this sort in her lessons in the schoolroom, and though this was not a <i>very</i> good opportunity for showing off her knowledge, as there was no one to listen to her, still it was good practice to say it over) “—yes, that’s about the right distance—but then I wonder what Latitude or Longitude I’ve got to?” (Alice had no idea what Latitude was, or Longitude either, but thought they were nice grand words to say.)",
        "SCENE",
        "Presently she began again. “I wonder if I shall fall right <i>through</i> the earth! How funny it’ll seem to come out among the people that walk with their heads downward! The Antipathies, I think—” (she was rather glad there <i>was</i> no one listening, this time, as it didn’t sound at all the right word) “—but I shall have to ask them what the name of the country is, you know. Please, Ma’am, is this New Zealand or Australia?” (and she tried to curtsey as she spoke—fancy <i>curtseying</i> as you’re falling through the air! Do you think you could manage it?) “And what an ignorant little girl she’ll think me for asking! No, it’ll never do to ask: perhaps I shall see it written up somewhere.”",
        "Down, down, down. There was nothing else to do, so Alice soon began talking again. “Dinah’ll miss me very much to-night, I should think!” (Dinah was the cat.) “I hope they’ll remember her saucer of milk at tea-time. Dinah my dear! I wish you were down here with me! There are no mice in the air, I’m afraid, but you might catch a bat, and that’s very like a mouse, you know. But do cats eat bats, I wonder?” And here Alice began to get rather sleepy, and went on saying to herself, in a dreamy sort of way, “Do cats eat bats? Do cats eat bats?” and sometimes, “Do bats eat cats?” for, you see, as she couldn’t answer either question, it didn’t much matter which way she put it.",
    ]),
    ("CHAPTER II.", "The Pool of Tears", [
        "“Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); “now I’m opening out like the largest telescope that ever was! Good-bye, feet!” (for when she looked down at her feet, they seemed to be almost out of sight, they were getting so far off).",
        "“Oh, my poor little feet, I wonder who will put on your shoes and stockings for you now, dears? I’m sure <i>I</i> shan’t be able! I shall be a great deal too far off to trouble myself about you: you must manage the best way you can;—but I must be kind to them,” thought Alice, “or perhaps they won’t walk the way I want to go! Let me see: I’ll give them a new pair of boots every Christmas.”",
        "And she went on planning to herself how she would manage it. “They must go by the carrier,” she thought; “and how funny it’ll seem, sending presents to one’s own feet! And how odd the directions will look!",
        "Just then her head struck against the roof of the hall: in fact she was now more than nine feet high, and she at once took up the little golden key and hurried off to the garden door.",
        "Poor Alice! It was as much as she could do, lying down on one side, to look through into the garden with one eye; but to get through was more hopeless than ever: she sat down and began to cry again.",
        "“You ought to be ashamed of yourself,” said Alice, “a great girl like you,” (she might well say this), “to go on crying in this way! Stop this moment, I tell you!” But she went on all the same, shedding gallons of tears, until there was a large pool all round her, about four inches deep and reaching half down the hall.",
        "After a time she heard a little pattering of feet in the distance, and she hastily dried her eyes to see what was coming. It was the White Rabbit returning, splendidly dressed, with a pair of white kid gloves in one hand and a large fan in the other: he came trotting along in a great hurry, muttering to himself as he came, “Oh! the Duchess, the Duchess! Oh! won’t she be savage if I’ve kept her waiting!” Alice felt so desperate that she was ready to ask help of any one; so, when the Rabbit came near her, she began, in a low, timid voice, “If you please, sir—” The Rabbit started violently, dropped the white kid gloves and the fan, and skurried away into the darkness as hard as he could go.",
        "Alice took up the fan and gloves, and, as the hall was very hot, she kept fanning herself all the time she went on talking: “Dear, dear! How queer everything is to-day! And yesterday things went on just as usual. I wonder if I’ve been changed in the night? Let me think: was I the same when I got up this morning? I almost think I can remember feeling a little different. But if I’m not the same, the next question is, Who in the world am I? Ah, <i>that’s</i> the great puzzle!” And she began thinking over all the children she knew that were of the same age as herself, to see if she could have been changed for any of them.",
    ]),
    ("CHAPTER III.", "A Caucus-Race and a Long Tale", [
        "They were indeed a queer-looking party that assembled on the bank—the birds with draggled feathers, the animals with their fur clinging close to them, and all dripping wet, cross, and uncomfortable.",
        "The first question of course was, how to get dry again: they had a consultation about this, and after a few minutes it seemed quite natural to Alice to find herself talking familiarly with them, as if she had known them all her life. Indeed, she had quite a long argument with the Lory, who at last turned sulky, and would only say, “I am older than you, and must know better;” and this Alice would not allow without knowing how old it was, and, as the Lory positively refused to tell its age, there was no more to be said.",
        "At last the Mouse, who seemed to be a person of authority among them, called out, “Sit down, all of you, and listen to me! <i>I’ll</i> soon make you dry enough!” They all sat down at once, in a large ring, with the Mouse in the middle. Alice kept her eyes anxiously fixed on it, for she felt sure she would catch a bad cold if she did not get dry very soon.",
        "“Ahem!” said the Mouse with an important air, “are you all ready? This is the driest thing I know. Silence all round, if you please! ‘William the Conqueror, whose cause was favoured by the pope, was soon submitted to by the English, who wanted leaders, and had been of late much accustomed to usurpation and conquest. Edwin and Morcar, the earls of Mercia and Northumbria—’”",
        "“Ugh!” said the Lory, with a shiver.",
        "“I beg your pardon!” said the Mouse, frowning, but very politely: “Did you speak?”",
        "“Not I!” said the Lory hastily.",
        "“I thought you did,” said the Mouse. “—I proceed. ‘Edwin and Morcar, the earls of Mercia and Northumbria, declared for him: and even Stigand, the patriotic archbishop of Canterbury, found it advisable—’”",
        "“Found <i>what</i>?” said the Duck.",
        "“Found <i>it</i>,” the Mouse replied rather crossly: “of course you know what ‘it’ means.”",
        "“I know what ‘it’ means well enough, when <i>I</i> find a thing,” said the Duck: “it’s generally a frog or a worm. The question is, what did the archbishop find?”",
        "The Mouse did not notice this question, but hurriedly went on, “‘—found it advisable to go with Edgar Atheling to meet William and offer him the crown. William’s conduct at first was moderate. But the insolence of his Normans—’ How are you getting on now, my dear?” it continued, turning to Alice as it spoke.",
        "“As wet as ever,” said Alice in a melancholy tone: “it doesn’t seem to dry me at all.”",
    ]),
]


def picture_png(width, height, label):
    """A simple generated picture so the sample has real raster images."""
    from PIL import Image as PILImage, ImageDraw
    img = PILImage.new("RGB", (width * 2, height * 2), "#27405f")
    draw = ImageDraw.Draw(img)
    for i in range(9):
        cx, cy, r = width * 2 * (0.1 + 0.1 * i), height * 2 * (0.75 - 0.06 * (i % 4)), 24 + 8 * (i % 3)
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill="#e9c46a" if i % 2 else "#f4a261")
    if label:
        draw.text((width, height * 0.5), label, fill="white", anchor="mm", font_size=40)
    out = io.BytesIO()
    img.save(out, "PNG")
    out.seek(0)
    return out


def build(path, bookmarks=True):
    page_w, page_h = A5
    margin_x, margin_top, margin_bottom = 18 * mm, 20 * mm, 20 * mm

    body = ParagraphStyle("Body", fontName="Times-Roman", fontSize=11, leading=14.5, alignment=TA_JUSTIFY,
                          firstLineIndent=16, hyphenationLang="en_US", embeddedHyphenation=1,
                          uriWasteReduce=0.3)
    first = ParagraphStyle("First", parent=body, firstLineIndent=0)
    chapter_number = ParagraphStyle("ChapterNumber", fontName="Times-Roman", fontSize=13, leading=16,
                                    alignment=TA_CENTER, spaceBefore=40)
    chapter_title = ParagraphStyle("ChapterTitle", fontName="Times-Bold", fontSize=20, leading=24,
                                   alignment=TA_CENTER, spaceBefore=6, spaceAfter=26)
    scene = ParagraphStyle("Scene", parent=body, alignment=TA_CENTER, firstLineIndent=0,
                           spaceBefore=8, spaceAfter=8)
    small = ParagraphStyle("Small", fontName="Times-Roman", fontSize=9, leading=12, alignment=TA_CENTER)
    caption = ParagraphStyle("Caption", fontName="Times-Italic", fontSize=10, leading=13, alignment=TA_CENTER,
                             spaceBefore=10)

    state = {"chapter": TITLE}

    class Doc(BaseDocTemplate):
        def afterFlowable(self, flowable):
            if isinstance(flowable, Paragraph) and flowable.style.name == "ChapterTitle":
                text = flowable.getPlainText()
                state["chapter"] = text
                if bookmarks:
                    state["n"] = state.get("n", 0) + 1
                    key = "ch%d" % state["n"]
                    self.canv.bookmarkPage(key, fit="XYZ", top=self.frame._y + flowable.height + 60)
                    self.canv.addOutlineEntry(state["number"] + " " + text, key, level=0)
            if isinstance(flowable, Paragraph) and flowable.style.name == "ChapterNumber":
                state["number"] = flowable.getPlainText()

    def furniture(canvas, doc):
        canvas.saveState()
        canvas.setFont("Times-Italic", 9)
        page = doc.page
        head = TITLE if page % 2 == 0 else state["chapter"]
        canvas.drawCentredString(page_w / 2, page_h - 12 * mm, head)
        canvas.setFont("Times-Roman", 9)
        canvas.drawCentredString(page_w / 2, 11 * mm, str(page))
        canvas.restoreState()

    def cover(canvas, doc):
        canvas.saveState()
        canvas.drawImage(ImageReader(picture_png(420, 595, "")), 0, 0, page_w, page_h)
        canvas.setFillColorRGB(1, 1, 1)
        canvas.setFont("Times-Bold", 24)
        canvas.drawCentredString(page_w / 2, page_h * 0.72, "Alice’s Adventures")
        canvas.drawCentredString(page_w / 2, page_h * 0.72 - 30, "in Wonderland")
        canvas.setFont("Times-Roman", 16)
        canvas.drawCentredString(page_w / 2, page_h * 0.18, AUTHOR)
        canvas.restoreState()

    frame = Frame(margin_x, margin_bottom, page_w - 2 * margin_x, page_h - margin_top - margin_bottom, id="f",
                  leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    doc = Doc(path, pagesize=A5, title=TITLE, author=AUTHOR, subject="Test fixture")
    doc.addPageTemplates([
        PageTemplate(id="cover", frames=[frame], onPage=cover),
        PageTemplate(id="plain", frames=[frame]),
        PageTemplate(id="body", frames=[frame], onPage=furniture),
    ])

    story = [NextPageTemplate("plain"), PageBreak()]
    story += [Spacer(1, 120), Paragraph("Copyright notice: this text is in the public domain.", small),
              Paragraph("Sample edition made for testing.", small)]
    story += [NextPageTemplate("body")]

    for index, (number, title, paragraphs) in enumerate(CHAPTERS):
        story += [PageBreak(), Paragraph(number, chapter_number), Paragraph(title, chapter_title)]
        for i, text in enumerate(paragraphs):
            if text == "SCENE":
                story.append(Paragraph("*   *   *", scene))
            else:
                story.append(Paragraph(text, first if i == 0 or paragraphs[i - 1] == "SCENE" else body))
        if index == 0:
            story += [PageBreak(), Spacer(1, 60),
                      Image(picture_png(300, 220, "The White Rabbit"), width=110 * mm, height=80 * mm),
                      Paragraph("The White Rabbit.", caption)]
    doc.build(story)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--no-bookmarks", action="store_true")
    args = parser.parse_args()
    build(args.output, bookmarks=not args.no_bookmarks)
