I started building Morph because a simple file conversion on my Mac felt like too many steps: open an app, find the file, choose an export option, then hunt for the output.

I wanted the convenience of Windows’ Tichau File Converter in Finder: right-click → Convert To → choose a format.

The path from that idea to a working native utility taught me how much hides behind a small menu. Finder has real extension limits. Background conversion needs to stay available without opening windows. And a format choice is only useful when the exact route is supported on that Mac.

So Morph is built around source-aware conversion routes, local engines, and a Finder menu that only shows useful choices. It preserves originals, handles output collisions safely, and asks before installing optional tools. A one-page PDF can become one PNG; batch operations and related tools live in the app instead of cluttering the right-click menu.

It’s a Swift and SwiftUI project, open source under Apache 2.0, and still being prepared for its first public release. Before I announce it, I’m arranging an independent security and issue review.

I built Morph to remove a little friction from a task we all do. I’d love to know: what file conversion or small Mac workflow would you like to make disappear?

Project: https://github.com/Lakshay-13/morph
