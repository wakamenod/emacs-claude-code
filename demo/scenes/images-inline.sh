# The order of the scene of demo/scenes/images-inline.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh images-inline
#
# One real session.  Three of the four ways a picture arrives are fed in
# through `ecc-dispatch', which is the door a live message comes in by;
# the fourth is really sent, as an `@path' on a prompt.

say "0.3.0 -- pictures and video in the transcript"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "1. A real session, and a turn to draw into"; sleep 4
e "(demo-start-session)"; sleep 10
e "(demo-show-transcript)"; sleep 4
e "(demo-open-turn \"Show me the picture, the GIF and the video\")"; sleep 3

say "2. First way: an image block on an assistant message"; sleep 5
e "(demo-message-image)"; sleep 3
e "(demo-show-transcript)"; sleep 5
e "(demo-report-images)"; sleep 8
say "Before this, that block became an unknown node drawn as two thousand characters of base64"; sleep 7

say "3. Second way: an image inside a tool_result -- a Read of a .png"; sleep 6
e "(demo-tool-result-image)"; sleep 3
e "(demo-show-transcript)"; sleep 5
e "(demo-report-images)"; sleep 8
say "The same image twice is one file and one node: the sha1 of its bytes is its name"; sleep 7
e "(demo-report-image-dir)"; sleep 8

say "4. Third way: a tool that named a file, with no picture in its result"; sleep 6
e "(demo-file-path-image)"; sleep 3
e "(demo-show-transcript)"; sleep 5
e "(demo-report-images)"; sleep 8
say "A GIF starts moving as soon as it is drawn, and loops while it is on screen"; sleep 6
e "(demo-report-timers)"; sleep 7

say "5. A video cannot be drawn, so ffmpeg pulls its first frame out"; sleep 6
e "(demo-video-thumbnail)"; sleep 4
e "(demo-show-transcript)"; sleep 4
say "The line naming the file stands until the frame lands -- the subprocess is never waited for"; sleep 7
e "(demo-report-images)"; sleep 8
e "(demo-finish-turn)"; sleep 3

say "6. A tool that brought a picture comes up open -- a screenshot behind a fold is one nobody sees"; sleep 8
e "(demo-report-folds)"; sleep 9
e "(demo-point-on-tool)"; sleep 4
e "(demo-fold-at-point)"; sleep 4
e "(demo-report-folds)"; sleep 8
e "(demo-show-transcript)"; sleep 4
say "TAB still folds it, and what the user folded is remembered"; sleep 6
e "(demo-fold-at-point)"; sleep 4
e "(demo-report-folds)"; sleep 7

say "7. Nothing reached the buffer as base64"; sleep 5
e "(demo-report-no-base64)"; sleep 8
e "(demo-report-image-dir)"; sleep 8

say "8. I stops the picture at point moving, and sets it going again"; sleep 6
e "(demo-point-on-image \"moving\")"; sleep 5
e "(demo-say-transcript-key \"I\")"; sleep 4
e "(demo-transcript-key \"I\")"; sleep 4
e "(demo-report-images)"; sleep 7
e "(demo-report-timers)"; sleep 7
e "(demo-transcript-key \"I\")"; sleep 4
e "(demo-report-images)"; sleep 7
e "(demo-report-timers)"; sleep 7

say "8. RET opens the picture at point -- a still in image-mode"; sleep 6
e "(demo-point-on-image \"picture\")"; sleep 4
e "(demo-say-transcript-key \"RET\")"; sleep 4
e "(demo-transcript-key \"RET\")"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-opened)"; sleep 8
e "(demo-close-image-buffer)"; sleep 4

say "9. ecc-image-inline turns the drawing off -- the line that names the file stays"; sleep 7
e "(demo-toggle-inline)"; sleep 4
e "(demo-show-transcript)"; sleep 4
e "(demo-report-images)"; sleep 8
e "(demo-report-timers)"; sleep 7
say "That is what a terminal frame, a batch Emacs and a build without the library see"; sleep 7
e "(demo-toggle-inline)"; sleep 4
e "(demo-show-transcript)"; sleep 4
e "(demo-report-images)"; sleep 8

say "10. Fourth way: the images a prompt attaches as @path.  This one is really sent"; sleep 7
e "(demo-send-with-attachment)"; sleep 20
e "(demo-show-transcript)"; sleep 5
e "(demo-report-images)"; sleep 8
e "(demo-report-no-base64)"; sleep 8
e "(demo-report-image-dir)"; sleep 8

e "(demo-save-log \"/tmp/ecc-demo-images-inline-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 4
say "That is the whole of the pictures."; sleep 5

