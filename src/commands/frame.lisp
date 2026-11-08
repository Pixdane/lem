(defpackage :lem-core/commands/frame
  (:use :cl :lem-core)
  (:export :toggle-frame-fullscreen
           :backdrop-opacity-set
           :backdrop-blur-set)
  #+sbcl
  (:lock t))
(in-package :lem-core/commands/frame)

(define-command toggle-frame-fullscreen () ()
  "Toggles fullscreen."
  (setf (display-fullscreen-p) (not (display-fullscreen-p))))

(define-command maximize-frame () ()
  "Maximize the frame."
  (lem-if:maximize-frame (implementation)))

(define-command minimize-frame () ()
  "Minimize the frame."
  (lem-if:minimize-frame (implementation)))

(define-command backdrop-opacity-set (percent) ((:number "Backdrop opacity (0-100): "))
  "Set the window background opacity percentage (0-100, where 100 is fully opaque)."
  (let ((clamped (max 0 (min 100 percent))))
    (set-backdrop :opacity (/ clamped 100.0))))

(define-command backdrop-blur-set (radius) ((:number "Backdrop blur radius (px): "))
  "Set the native window backdrop Gaussian blur radius in pixels (0 disables blur)."
  (set-backdrop :blur (max 0 (truncate radius))))
