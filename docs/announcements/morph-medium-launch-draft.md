# I Built Morph Because Converting a File Shouldn’t Feel Like a Project

*A small annoyance pulled me into Finder extensions, background helpers, conversion engines, and the details that make a Mac utility feel native.*

There’s a kind of task that should take five seconds and somehow takes ten minutes.

You have a file. You need it in another format. So you open an app, find the file, work out which export option applies, choose a destination, and then go looking for the result. It’s not hard. It’s just a surprising amount of ceremony for something as ordinary as converting a file.

I wanted to make that simpler on my Mac.

The idea came from the convenience of Windows’ Tichau File Converter: right-click a file, choose an output format, and get on with your day. I wanted the same feeling in Finder: **right-click → Convert To → choose a format**. No separate window to manage and no need to know which engine sits behind the conversion.

That sounded like a small utility. It quickly became a lesson in how much work hides behind a simple menu.

## The menu was the first hard part

I started by exploring Quick Actions and Finder extensions. macOS doesn’t let a third-party Quick Action add a dynamic format submenu inside Finder’s built-in Quick Actions section. Finder Sync can build a selection-aware menu, but it has its own boundaries and is intended primarily for sync-related features.

Morph now uses a native Finder contextual-menu entry called **Convert To**. It shows formats that make sense for the selected file and that the installed engines can actually produce. A PNG can offer image outputs; a PDF can offer page images. When several files are selected, Morph only offers an output route that works for the whole selection. The list can be edited in the app.

There were also smaller but more frustrating problems. At one point, choosing a conversion opened two windows. I wanted Finder conversion to open no windows at all. Another time, macOS said the Morph application was no longer open when Finder tried to hand off work. The conversion needed a reliable background process that could remain ready without taking over the desktop.

Those bugs changed the design. Morph now hands Finder’s request to a small background helper, keeps the conversion out of the main window, and uses a menu-bar item for progress and cancellation. The main app is there when you want to manage engines or settings; it doesn’t have to appear just to convert one file.

## A format pair is a promise

A conversion menu is only useful if its choices are honest. Having a reader for one format and a writer for another doesn’t automatically mean every pair works. The app has to know what the selected file contains, which codecs or document readers are installed, and whether the requested output is supported on this Mac.

That led me to build Morph around a registry of conversion routes rather than hard-coding formats into the interface. Apple’s frameworks handle local image and PDF work where they fit. Optional engines such as FFmpeg, Pandoc, LibreOffice, ImageMagick, Ghostscript, and 7-Zip add capabilities when installed. The interface asks the registry what is available and keeps unsupported routes out of the menu.

Auditing those routes caught an obvious inconsistency: Morph offered MP3 to M4A but not M4A back to MP3. The media engine could perform both, but the catalogue didn’t describe both directions. Fixes like that are a reminder that “supports audio conversion” is not a useful promise by itself. The actual input and output pairs matter.

When an optional engine is missing, Morph explains what it enables and asks before installing it. Conversions run locally; there is no cloud conversion service. Originals stay in place, and outputs use collision-safe names rather than silently replacing existing files.

## The details are the product

The small choices are what make a utility feel considerate. A one-page PDF exported as images should give you one PNG. A multipage PDF should keep its page images together. A conversion should preserve its source, tell you when a route isn’t available, and leave a clear result in Finder. Batch selection should help instead of making users repeat the same task file by file.

Once the basic conversion flow worked, it made sense to bring related operations into the app: image resizing, PDF merging and page extraction, video trimming and compression, archive extraction, metadata inspection, and batch renaming. They share the same goals—local processing, understandable choices, and safe output behavior—but stay organized as operations rather than crowding the Finder menu.

Morph is written in Swift and SwiftUI, and it’s open source under Apache 2.0. It’s still a work in progress. I’m preparing it carefully, and before I make a public release announcement I want an independent review for security issues and other problems I may have missed. The Finder extension and macOS permission model also create practical limits that I’ll document rather than hide.

I started with one thought: converting a file should be easier than opening another app. Along the way, that became a project about respecting the small expectations people have of a native Mac utility—one menu, the right choices, no surprises, and the original file left safe.

That is what I’m trying to make with Morph.

If you have a conversion workflow that still feels unnecessarily complicated, I’d love to hear about it. It might be the next thing Morph needs to learn.

**Project:** [Morph on GitHub](https://github.com/Lakshay-13/morph)
