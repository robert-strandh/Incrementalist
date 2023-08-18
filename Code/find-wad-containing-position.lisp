(cl:in-package #:incrementalist)

;;; Return true if and only if the position indicated by
;;; RELATIVE-LINE-NUMBER and COLUMN-NUMBER is entirely before WAD.  If
;;; WAD is an absolute wad, then RELATIVE-LINE-NUMBER must be the
;;; absolute line number of the position.  If WAD is a relative wad,
;;; then RELATIVE-LINE-NUMBER must be the difference between the
;;; absolute line number of the position, and the start line of the
;;; wad to which WAD is relative.  The position is before WAD if
;;; either RELATIVE-LINE-NUMBER is strictly less than the start line
;;; of WAD, or if RELATIVE-LINE-NUMBER is equal to the start line of
;;; WAD, and COLUMN-NUMBER is less than or equal to the start column
;;; of WAD.
(defun position-is-before-wad-p (wad relative-line-number column-number)
  (or (< relative-line-number (start-line wad))
      (and (= relative-line-number (start-line wad))
           (<= column-number (start-column wad)))))

;;; Return true if and only if the position indicated by
;;; RELATIVE-LINE-NUMBER and COLUMN-NUMBER is entirely after WAD.  If
;;; WAD is an absolute wad, then RELATIVE-LINE-NUMBER must be the
;;; absolute line number of the position.  If WAD is a relative wad,
;;; then RELATIVE-LINE-NUMBER must be the difference between the
;;; absolute line number of the position, and the start line of the
;;; wad to which WAD is relative.  The position is after WAD if either
;;; RELATIVE-LINE-NUMBER is strictly greater than the sum of the start
;;; line of WAD and the height of WAD, or if RELATIVE-LINE-NUMBER is
;;; equal to the sum of the start line of WAD and the height of WAD,
;;; and COLUMN-NUMBER is greater than or equal to the end column of
;;; WAD.
(defun position-is-after-wad-p (wad relative-line-number column-number)
  (or (> relative-line-number (+ (start-line wad) (height wad)))
      (and (= relative-line-number (+ (start-line wad) (height wad)))
           (>= column-number (end-column wad)))))

;;; Return true if and only if the position indicated by
;;; RELATIVE-LINE-NUMBER and COLUMN-NUMBER is inside WAD.  If WAD is
;;; an absolute wad, then RELATIVE-LINE-NUMBER must be the absolute
;;; line number of the position.  If WAD is a relative wad, then
;;; RELATIVE-LINE-NUMBER must be the difference between the absolute
;;; line number of the position, and the start line of the wad to
;;; which WAD is relative.  The position is inside WAD if it is
;;; neither before WAD nor after WAD.
(defun position-is-inside-wad-p (wad relative-line-number column-number)
  (not (or (position-is-before-wad-p wad relative-line-number column-number)
           (position-is-after-wad-p wad relative-line-number column-number))))

;;; Return a top-level wad in the prefix of CACHE that contains the
;;; position indicated by LINE-NUMBER and COLUMN-NUMBER.  If no wad in
;;; the prefix contains the position, then return NIL.
(defun find-wad-containing-position-in-prefix (cache line-number column-number)
  (loop for wad in (prefix cache)
        until (position-is-after-wad-p wad line-number column-number)
        when (position-is-inside-wad-p wad line-number column-number)
          return wad))

;;; Helper function.
(defun traverse-relative-wads
    (wads line-number column-number reference-line-number)
  (loop for wad in wads
        for relative-line-number
          = (- line-number reference-line-number)
        until (position-is-before-wad-p
               wad relative-line-number column-number)
        when (position-is-inside-wad-p
              wad relative-line-number column-number)
          return (values wad (+ reference-line-number (start-line wad)))
        do (incf reference-line-number (start-line wad))))

;;; Return a top-level wad in the suffix of CACHE that contains the
;;; position indicated by LINE-NUMBER and COLUMN-NUMBER.  As a second
;;; return value, return the absolute line number of the start line of
;;; the wad that was found.  If no wad in the prefix contains the
;;; position, then return NIL.
(defun find-wad-containing-position-in-suffix (cache line-number column-number)
  (let ((suffix (suffix cache)))
    (cond ((null suffix)
           nil)
          ((position-is-inside-wad-p (first suffix) line-number column-number)
           (values (first suffix) (start-line (first suffix))))
          (t
           (traverse-relative-wads
            (rest suffix)
            line-number
            column-number
            (start-line (first suffix)))))))

;;; Return a list of pairs of the form (N . W) where W is a wad, and N
;;; is the absolute start line number of W, of wads containing the
;;; position defined by LINE-NUMBER and COLUMN-NUMBER.  The list is
;;; ordered from the innermost wad containing the position to the
;;; top-level wad containing the position.  The empty list is return
;;; if the position is inside no wad.
(defun find-wads-containing-position (cache line-number column-number)
  (let ((result '()))
    (labels ((traverse-children (children reference-line-number)
               (multiple-value-bind (wad absolute-start-line)
                   (traverse-relative-wads
                    children line-number column-number reference-line-number)
                 (if (null wad)
                     (return-from find-wads-containing-position result)
                     (progn (push (cons absolute-start-line wad) result)
                            (traverse-children
                             (children wad) absolute-start-line))))))
      (let ((wad (find-wad-containing-position-in-prefix
                  cache line-number column-number)))
        (if (null wad)
            (multiple-value-bind (wad absolute-line-number)
                (find-wad-containing-position-in-suffix
                 cache line-number column-number)
              (if (null wad)
                  nil
                  (progn
                    (push (cons absolute-line-number wad) result)
                    (traverse-children (children wad) absolute-line-number))))
            (progn
              (push (cons (start-line wad) wad) result)
              (traverse-children (children wad) (start-line wad))))))))
