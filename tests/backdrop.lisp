(defpackage :lem-tests/backdrop
  (:use :cl :rove :lem))
(in-package :lem-tests/backdrop)

(defclass backdrop-recording-interface (implementation)
  ((opacity
    :initform 1.0d0
    :accessor backdrop-recording-opacity)
   (blur
    :initform 0
    :accessor backdrop-recording-blur))
  (:documentation "Minimal implementation that records the backdrop values it receives.")
  (:default-initargs :name :backdrop-recording))

(defmethod lem-if:set-backdrop ((implementation backdrop-recording-interface)
                                &key (opacity nil opacity-p)
                                     (blur nil blur-p)
                                     &allow-other-keys)
  (when opacity-p
    (setf (backdrop-recording-opacity implementation) opacity))
  (when blur-p
    (setf (backdrop-recording-blur implementation) blur))
  t)

(defun float-close-p (x y &optional (tolerance 1d-6))
  "Return T when X and Y differ by less than TOLERANCE, whatever their float format."
  (< (abs (- (coerce x 'double-float) (coerce y 'double-float))) tolerance))

(defmacro with-recording-backdrop-interface ((name) &body body)
  "Run BODY with `lem:set-backdrop' routed to a fresh recording implementation NAME."
  `(let ((,name (make-instance 'backdrop-recording-interface)))
     (with-implementation ,name
       ,@body)))

(deftest backdrop-opacity-set-clamps-percentage
  (with-recording-backdrop-interface (implementation)
    (testing "mid-range percentages become [0,1] fractions"
      (backdrop-opacity-set 40)
      (ok (float-close-p 0.4 (backdrop-recording-opacity implementation))))
    (testing "percentages above 100 clamp to fully opaque"
      (backdrop-opacity-set 250)
      (ok (float-close-p 1.0 (backdrop-recording-opacity implementation))))
    (testing "negative percentages clamp to fully transparent"
      (backdrop-opacity-set -20)
      (ok (float-close-p 0.0 (backdrop-recording-opacity implementation))))))

(deftest backdrop-blur-set-clamps-radius
  (with-recording-backdrop-interface (implementation)
    (testing "fractional radii are truncated to whole pixels"
      (backdrop-blur-set 12.7)
      (ok (= 12 (backdrop-recording-blur implementation))))
    (testing "negative radii disable blur instead of being rejected"
      (backdrop-blur-set -5)
      (ok (= 0 (backdrop-recording-blur implementation))))))

(deftest darwin-transparency-feature-flag
  (testing "the feature flag is present exactly on Darwin builds"
    #+darwin
    (ok (member :darwin-transparency *features*))
    #-darwin
    (ok (not (member :darwin-transparency *features*)))))
