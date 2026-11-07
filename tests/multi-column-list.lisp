(defpackage :lem-tests/multi-column-list
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :fake-interface)
  (:import-from :lem-tests/utilities
                :make-text-buffer))
(in-package :lem-tests/multi-column-list)

;;; The function that writes the header attribute, the color helper it uses,
;;; and the popup-menu the checked items are read from are internal to
;;; `lem/multi-column-list' and `lem/popup-menu': no public command exposes
;;; the attribute put on a header line, so these tests reach them with `::'.

(defclass underline-color-interface (fake-interface)
  ()
  (:documentation "A frontend like lem-webview: it can color its underlines.")
  (:default-initargs :underline-color-support t))

(defclass colored-foreground-interface (underline-color-interface)
  ()
  (:documentation "A frontend that also reports an RGB foreground."))

(defmethod lem-if:get-foreground-color ((implementation colored-foreground-interface))
  "Report white, the way `lem-server' reports a webview client's foreground."
  (declare (ignore implementation))
  (lem:make-color 255 255 255))

(defmacro with-theme ((theme) &body body)
  "Run BODY with THEME as the current color theme, then restore the old one."
  `(let ((original (lem:current-theme)))
     (unwind-protect
          (progn (setf (lem:current-theme) ,theme)
                 ,@body)
       (setf (lem:current-theme) original))))

(defmacro with-interface ((class) &body body)
  "Run BODY with an instance of CLASS as the frontend implementation."
  `(lem:with-implementation (make-instance ,class)
     ,@body))

(defun header-underline-of (interface-class theme)
  "Return the :UNDERLINE value `put-header-attribute' writes under THEME.

INTERFACE-CLASS is instantiated as the frontend implementation.  The header
text lives in a real buffer, so the value returned is the one a frontend
would receive from `text-property-at'."
  (lem:with-current-buffers ()
    (with-theme (theme)
      (with-interface (interface-class)
        (let ((buffer (make-text-buffer "header")))
          (lem:with-point ((start (lem:buffer-point buffer))
                           (end (lem:buffer-point buffer)))
            (lem:line-end end)
            (lem/multi-column-list::put-header-attribute start end)
            (lem:attribute-underline (lem:text-property-at start :attribute))))))))

(deftest header-underline-under-a-color-aware-frontend
  (testing "\"lem-default\" has no theme foreground, so the frontend's RGB color is darkened"
    (ok (equal "#666666" (header-underline-of 'colored-foreground-interface "lem-default"))))
  (testing "\"lem-default\" without an RGB foreground falls back to a plain underline"
    (ok (eq t (header-underline-of 'underline-color-interface "lem-default"))))
  (testing "a theme foreground is darkened"
    (ok (equal "#666666" (header-underline-of 'underline-color-interface "emacs-dark"))))
  (testing "a frontend that cannot color underlines always gets a plain underline"
    (ok (eq t (header-underline-of 'fake-interface "emacs-dark")))))

(deftest darken-color-accepts-every-foreground-form
  (flet ((darken (color)
           (lem/multi-column-list::darken-color color :factor 0.6)))
    (testing "a lem:color struct"
      (ok (equal "#666666" (darken (lem:make-color 255 255 255)))))
    (testing "a color string"
      (ok (equal "#666666" (darken "#ffffff"))))
    (testing "a base-color keyword, resolved through the current theme"
      (with-theme ("lem-default")
        (ok (equal "#666666" (darken :base07)))))
    (testing "an unresolvable color returns NIL instead of signaling"
      (ok (null (darken nil)))
      (with-theme ("lem-default")
        (ok (null (darken :foreground)))))))

(deftest get-foreground-color-defaults-to-nil
  (with-interface ('fake-interface)
    (ok (null (lem-if:get-foreground-color (lem:implementation)))
        "a frontend that does not implement the method returns NIL"))
  (ok (null (lem-if:get-foreground-color (make-instance 'fake-interface))))
  (testing "subclasses inherit the NIL default"
    (ok (null (lem-if:get-foreground-color (make-instance 'underline-color-interface))))))

(defun make-list-without-focus-item ()
  "Return a multi-column-list whose popup menu holds no item to focus."
  (let ((multi-column-list (make-instance 'lem/multi-column-list:multi-column-list
                                          :items nil
                                          :columns '("Buffer")
                                          :use-check t)))
    (setf (lem/multi-column-list::multi-column-list-popup-menu multi-column-list)
          (make-instance 'lem/popup-menu::popup-menu
                         :buffer (lem:make-buffer "*multi-column-list test*"
                                                  :temporary t)))
    multi-column-list))

(deftest an-empty-filter-match-has-nothing-to-check
  (let ((multi-column-list (make-list-without-focus-item)))
    (ok (null (lem/multi-column-list::current-focus-item multi-column-list)))
    (ok (null (lem/multi-column-list::checked-items multi-column-list))
        "nothing is checked and there is no focus item, so nothing is acted on")
    (ok (null (lem/multi-column-list:collect-checked-items multi-column-list)))))

(deftest quitting-without-a-multi-column-list-is-a-no-op
  (lem:with-current-buffers ()
    (lem-fake-interface:with-fake-interface ()
      (ok (null (lem/multi-column-list::multi-column-list/quit))
          "C-g in a window that has no multi-column list must not signal"))))
