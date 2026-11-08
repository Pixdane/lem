(defpackage :lem-webview/darwin
  (:use :cl)
  (:export :set-window-appearance
           :dispatch-set-window-appearance
           :set-window-backdrop
           :dispatch-set-window-backdrop))
(in-package :lem-webview/darwin)

;;; macOS window appearance via Objective-C runtime
;;;
;;; Uses objc_msgSend to set NSAppearance on the key window.
;;; set-window-appearance takes a webview handle (for pre-event-loop use).
;;; dispatch-set-window-appearance uses GCD + [NSApp keyWindow] so the
;;; editor thread can change appearance without holding a native handle.

#+darwin
(progn

(cffi:define-foreign-library libobjc
  (:os-macosx "libobjc.dylib"))

(cffi:use-foreign-library libobjc)

(cffi:define-foreign-library skylight
  (:os-macosx "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"))

(ignore-errors
  (cffi:use-foreign-library skylight))

(cffi:defcfun ("CGSMainConnectionID" cgs-main-connection-id) :uint32)

(cffi:defcfun ("CGSSetWindowBackgroundBlurRadius" cgs-set-window-background-blur-radius) :int32
  (cid :uint32)
  (wid :uint32)
  (radius :int))

(cffi:defcfun ("objc_getClass" objc-get-class) :pointer
  (name :string))

(cffi:defcfun ("sel_registerName" sel-register-name) :pointer
  (name :string))

;; Fixed-arity objc_msgSend wrappers — avoids ARM64 variadic ABI issues.
;; objc_msgSend is not truly variadic; it uses the callee's ABI, so we
;; must declare the exact parameter types.

(cffi:defcfun ("objc_msgSend" objc-msg-send/no-arg) :pointer
  (self :pointer)
  (sel :pointer))

(cffi:defcfun ("objc_msgSend" objc-msg-send/ptr) :pointer
  (self :pointer)
  (sel :pointer)
  (arg :pointer))

(cffi:defcfun ("objc_msgSend" objc-msg-send/str) :pointer
  (self :pointer)
  (sel :pointer)
  (arg :string))

(cffi:defcfun ("objc_msgSend" objc-msg-send/bool) :void
  (self :pointer)
  (sel :pointer)
  (arg :bool))

(cffi:defcfun ("objc_msgSend" objc-msg-send/int64-ret) :int64
  (self :pointer)
  (sel :pointer))

(cffi:defcfun ("objc_msgSend" objc-msg-send/bool-ptr-ret) :pointer
  (self :pointer)
  (sel :pointer)
  (arg :bool))

(cffi:defcfun ("objc_msgSend" objc-msg-send/ptr-ptr) :void
  (self :pointer)
  (sel :pointer)
  (arg1 :pointer)
  (arg2 :pointer))

;; Grand Central Dispatch — dispatch work to the main thread without
;; needing a webview handle.
(cffi:defcfun ("dispatch_async_f" dispatch-async-f) :void
  (queue :pointer)
  (context :pointer)
  (work :pointer))

(defun main-dispatch-queue ()
  "Return the main dispatch queue (dispatch_get_main_queue)."
  (cffi:foreign-symbol-pointer "_dispatch_main_q"))

(defun %get-key-window ()
  "Return the NSWindow that is the current key window, or a null pointer."
  (let* ((nsapp (objc-msg-send/no-arg
                 (objc-get-class "NSApplication")
                 (sel-register-name "sharedApplication")))
         (window (objc-msg-send/no-arg nsapp (sel-register-name "keyWindow"))))
    window))

(defun %set-nswindow-appearance (nswindow mode)
  "Set NSAppearance on NSWINDOW to MODE (:dark or :light).
Must be called on the main thread."
  (when (or (null nswindow) (cffi:null-pointer-p nswindow))
    (return-from %set-nswindow-appearance nil))
  (let* ((appearance-name (ecase mode
                            (:dark "NSAppearanceNameDarkAqua")
                            (:light "NSAppearanceNameAqua")))
         (ns-appearance-class (objc-get-class "NSAppearance"))
         (ns-name (objc-msg-send/str
                   (objc-get-class "NSString")
                   (sel-register-name "stringWithUTF8String:")
                   appearance-name))
         (appearance (objc-msg-send/ptr
                      ns-appearance-class
                      (sel-register-name "appearanceNamed:")
                      ns-name)))
    (when (cffi:null-pointer-p appearance)
      (return-from %set-nswindow-appearance nil))
    (objc-msg-send/ptr nswindow
                       (sel-register-name "setAppearance:")
                       appearance)
    mode))

;; GCD callbacks — dispatch_async_f signature: void (*)(void *)
(cffi:defcallback gcd-set-dark-appearance :void ((context :pointer))
  (declare (ignore context))
  (%set-nswindow-appearance (%get-key-window) :dark))

(cffi:defcallback gcd-set-light-appearance :void ((context :pointer))
  (declare (ignore context))
  (%set-nswindow-appearance (%get-key-window) :light))

(defun set-window-appearance (webview-handle mode)
  "Set the macOS window frame appearance for WEBVIEW-HANDLE.
MODE should be :dark or :light. Called before the event loop starts,
so it runs directly on the main thread with the handle available."
  (%set-nswindow-appearance (webview:webview-get-window webview-handle) mode))

(defun dispatch-set-window-appearance (mode)
  "Set the macOS window frame appearance via GCD main queue dispatch.
Uses [NSApp keyWindow] to find the window, so no webview handle is needed.
Safe to call from any thread."
  (dispatch-async-f (main-dispatch-queue)
                    (cffi:null-pointer)
                    (ecase mode
                      (:dark (cffi:callback gcd-set-dark-appearance))
                      (:light (cffi:callback gcd-set-light-appearance))))
  mode)

;; The GCD callback cannot carry a Lisp closure, so the values it needs are
;; staged in these globals just before the block is queued. Updates come from
;; the editor thread, so the last write wins; a block queued concurrently by an
;; out-of-band caller may apply the newer values, which is harmless.
(defvar *pending-backdrop-webview-handle* nil)
(defvar *pending-backdrop-opacity* 1.0d0)
(defvar *pending-backdrop-blur* 0)

(defun %valid-ptr (ptr)
  (and (cffi:pointerp ptr)
       (not (cffi:null-pointer-p ptr))
       ptr))

(defun %resolve-nswindow (webview-handle)
  (or (when (%valid-ptr webview-handle)
        (%valid-ptr (webview:webview-get-window webview-handle)))
      (%valid-ptr (%get-key-window))))

(defun %resolve-wkwebview (webview-handle)
  "Return the WKWebView owned by WEBVIEW-HANDLE, or NIL.
Only a real webview handle identifies a WKWebView. Falling back to the key
window's content view is not safe here: -setValue:forKey: with the private
`drawsBackground' key on a non-WKWebView raises an Objective-C exception that
CFFI cannot unwind."
  (when (%valid-ptr webview-handle)
    ;; WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER = 2 (WKWebView*)
    (%valid-ptr (webview:webview-get-native-handle webview-handle 2))))

(defun %apply-window-backdrop (webview-handle opacity blur)
  "Configure NSWindow transparency, SkyLight Gaussian blur, and WKWebView background.
Must be called on the main thread."
  (let* ((transparent-p (< opacity 1.0d0))
         (nswindow (%resolve-nswindow webview-handle))
         (wkwebview (%resolve-wkwebview webview-handle)))
    (when nswindow
      (objc-msg-send/bool nswindow
                          (sel-register-name "setOpaque:")
                          (not transparent-p))
      (let* ((nscolor-class (objc-get-class "NSColor"))
             (color-sel (sel-register-name
                         (if transparent-p "clearColor" "windowBackgroundColor")))
             (bg-color (objc-msg-send/no-arg nscolor-class color-sel)))
        (when (%valid-ptr bg-color)
          (objc-msg-send/ptr nswindow
                             (sel-register-name "setBackgroundColor:")
                             bg-color)))
      (objc-msg-send/no-arg nswindow (sel-register-name "invalidateShadow"))
      (let ((wid (objc-msg-send/int64-ret nswindow (sel-register-name "windowNumber"))))
        (when (plusp wid)
          (ignore-errors
            (cgs-set-window-background-blur-radius
             (cgs-main-connection-id)
             wid
             (if transparent-p (max 0 blur) 0))))))
    (when wkwebview
      (let ((ns-bool (objc-msg-send/bool-ptr-ret
                      (objc-get-class "NSNumber")
                      (sel-register-name "numberWithBool:")
                      (not transparent-p)))
            (ns-key (objc-msg-send/str
                     (objc-get-class "NSString")
                     (sel-register-name "stringWithUTF8String:")
                     "drawsBackground")))
        (when (and (%valid-ptr ns-bool) (%valid-ptr ns-key))
          (objc-msg-send/ptr-ptr wkwebview
                                 (sel-register-name "setValue:forKey:")
                                 ns-bool
                                 ns-key))))
    t))

(cffi:defcallback gcd-apply-window-backdrop :void ((context :pointer))
  (declare (ignore context))
  (%apply-window-backdrop *pending-backdrop-webview-handle*
                          *pending-backdrop-opacity*
                          *pending-backdrop-blur*))

(defun set-window-backdrop (webview-handle &key (opacity 1.0) (blur 0))
  "Apply window backdrop settings directly on the main thread."
  (%apply-window-backdrop webview-handle
                          (coerce opacity 'double-float)
                          (max 0 (truncate blur))))

(defun dispatch-set-window-backdrop (webview-handle &key (opacity 1.0) (blur 0))
  "Schedule window backdrop update onto the macOS main thread via GCD."
  (setf *pending-backdrop-webview-handle* webview-handle
        *pending-backdrop-opacity* (coerce opacity 'double-float)
        *pending-backdrop-blur* (max 0 (truncate blur)))
  (dispatch-async-f (main-dispatch-queue)
                    (cffi:null-pointer)
                    (cffi:callback gcd-apply-window-backdrop)))

) ; end #+darwin progn

#-darwin
(progn
(defun set-window-appearance (webview-handle mode)
  "No-op: window appearance is only supported on macOS."
  (declare (ignore webview-handle mode))
  nil)
(defun dispatch-set-window-appearance (mode)
  "No-op: window appearance is only supported on macOS."
  (declare (ignore mode))
  nil)
(defun set-window-backdrop (webview-handle &key (opacity 1.0) (blur 0))
  "No-op: native macOS backdrop is only supported on Darwin."
  (declare (ignore webview-handle opacity blur))
  nil)
(defun dispatch-set-window-backdrop (webview-handle &key (opacity 1.0) (blur 0))
  "No-op: native macOS backdrop is only supported on Darwin."
  (declare (ignore webview-handle opacity blur))
  nil)
) ; end #-darwin progn
