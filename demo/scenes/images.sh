# The order of the scene of demo/scenes/images.el, and how long each step
# is held.  Read by demo/record.sh, which defines `e' (run a form in the
# demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh images
#
# One real session, one real round trip with a picture attached to the
# prompt, and the other three ways an image reaches the transcript
# handed to the dispatcher as the stream brings them.

say "0.3.0 -- images and video in the transcript"; sleep 5
e "(demo-frame)"; sleep 2

say "1. A session, and a picture attached to a prompt as @path"; sleep 5
e "(demo-start-session)"; sleep 8
e "(demo-attach-and-send)"; sleep 4
e "(demo-frame)"; sleep 2
say "The prompt carries @chart.png, and the picture is drawn in the band the user typed in"; sleep 12
e "(demo-frame)"; sleep 8

say "2. An image block on an assistant message -- a screenshot from an MCP tool"; sleep 6
e "(demo-message-image)"; sleep 4
e "(demo-frame)"; sleep 6

say "3. An image inside a tool_result: a Read of a .png, answered with the picture"; sleep 6
e "(demo-result-image)"; sleep 4
e "(demo-frame)"; sleep 6
say "Drawn inside the tool call, after the result clip -- a long result is not what decides whether it is seen"; sleep 9

say "4. A file a tool only NAMED: spinner.gif, which starts moving as it is drawn"; sleep 7
e "(demo-gif-file)"; sleep 4
e "(demo-frame)"; sleep 6
e "(demo-goto-gif)"; sleep 3
e "(demo-report-animation)"; sleep 7

say "5. v stops it, and v sets it moving again"; sleep 5
e "(demo-toggle-animation)"; sleep 3
e "(demo-report-animation)"; sleep 7
e "(demo-toggle-animation)"; sleep 3
e "(demo-report-animation)"; sleep 7

say "6. A video cannot be drawn, so ffmpeg's first frame stands in for it"; sleep 6
e "(demo-video-file)"; sleep 5
e "(demo-frame)"; sleep 8
say "The line naming the file stands until the frame lands -- nothing waits for ffmpeg"; sleep 8

say "7. What the buffer actually holds"; sleep 4
e "(demo-report-no-base64)"; sleep 10
e "(demo-report-images)"; sleep 9
e "(demo-report-files)"; sleep 9
say "One file per sha1: the same picture arriving twice is one file and one node"; sleep 8

say "8. ecc-image-inline -- I in the menu -- turns the drawing off"; sleep 6
e "(demo-toggle-inline)"; sleep 5
e "(demo-frame)"; sleep 7
say "Each picture is the line that names it: a copy, a search and a batch Emacs all find the name"; sleep 9
e "(demo-toggle-inline)"; sleep 5
e "(demo-frame)"; sleep 6

e "(demo-cleanup)"; sleep 5
say "That is the whole of the images work."; sleep 6
