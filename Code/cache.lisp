(cl:in-package #:incrementalist)

;;; We do not use the line object from Cluffer directly, because the
;;; contents of such a line may change after we have asked for it, so
;;; that we get a different contents each time we ask for it.  But we
;;; still need the line object from Cluffer, because that one is used
;;; as a comparison in the update protocol.  The solution is to have
;;; two parallel editable sequences, one containing Cluffer lines and
;;; the other containing strings.  The sequence containing strings is
;;; then used as an input to the parser.

(defclass cache ()
  (;; This slot contains the Cluffer buffer that is being analyzed by
   ;; this cache instance.
   (%cluffer-buffer :initarg :cluffer-buffer :reader cluffer-buffer)
   (%lines :initform (make-instance 'flx:standard-flexichain)
           :reader lines)
   (%cluffer-lines :initform (make-instance 'flx:standard-flexichain)
                   :reader cluffer-lines)
   ;; The prefix contains top-level wads in reverse order, so that the
   ;; last wad in the prefix is the first wad in the buffer.  Every
   ;; top-level wad in the prefix has an absolute line number.
   (%prefix :initform '() :accessor prefix)
   ;; The suffix contains top-level wads in the right order.  The
   ;; first top-level wad on the suffix has an absolute line number.
   ;; All the others have relative line numbers.
   (%suffix :initform '() :accessor suffix)
   ;; The residue is normally empty.  The SCAVENGE phase puts orphan
   ;; wads that are still valid on the residue, and these are used by
   ;; the READ-FORMS phase to avoid reading characters when the result
   ;; is known.
   (%residue :initform '() :accessor residue)
   (%worklist :initform '() :accessor worklist)
   ;; The time stamp passed to and returned by the Cluffer update
   ;; protocol.
   (%time-stamp :initform nil :accessor time-stamp)
   ;; This slot contains the counter that is maintained during the
   ;; execution of the update function.
   (%line-counter :initform 0 :accessor line-counter)
   ;; This slot contains a list that parallels the prefix and it
   ;; contains the width of the prefix starting with the first element
   ;; of the prefix.
   (%prefix-width :initform '() :accessor prefix-width)
   ;; This slot contains a list that parallels the suffix and it
   ;; contains the width of the suffix starting with the first element
   ;; of the suffix.
   (%suffix-width :initform '() :accessor suffix-width)))

;;; Given a cache and an interval of lines, return the maxium length
;;; of any lines in the interval.
(defun max-line-length (cache first-line-number last-line-number)
  (loop for line-number from first-line-number to last-line-number
        maximize (line-length cache line-number)))

(defgeneric pop-from-suffix (cache)
  (:method ((cache cache))
    (with-accessors ((suffix suffix)
                     (suffix-width suffix-width))
        cache
      (assert (not (null suffix)))
      (pop suffix-width)
      (let ((result (pop suffix)))
        (unless (null suffix)
          (relative-to-absolute (first suffix) (start-line result)))
        result))))

(defgeneric push-to-suffix (cache wad)
  (:method ((cache cache) (wad wad))
    (assert (not (relative-p wad)))
    (with-accessors ((suffix suffix)
                     (prefix prefix)
                     (suffix-width suffix-width)
                     (line-count line-count))
        cache
      (if (null suffix)
          (progn
            (setf (right-sibling wad) nil)
            (push (max (max-line-length
                        cache (1+ (end-line wad)) (1- line-count))
                       (max-line-width wad))
                  suffix-width))
          (progn
            (setf (right-sibling wad) (first suffix))
            (setf (left-sibling (first suffix)) wad)
            (absolute-to-relative (first suffix) (start-line wad))
            (push (max (first suffix-width)
                       (max-line-length
                        cache
                        (1+ (end-line wad))
                        (1- (start-line (first suffix))))
                       (max-line-width wad))
                  suffix-width)))
      (if (null prefix)
          (setf (left-sibling wad) nil)
          (progn (setf (left-sibling wad) (first prefix))
                 (setf (right-sibling (first prefix)) wad)))
      (push wad suffix))))

(defgeneric pop-from-prefix (cache)
  (:method ((cache cache))
    (pop (prefix-width cache))
    (pop (prefix cache))))

(defgeneric push-to-prefix (cache wad)
  (:method ((cache cache) (wad wad))
    (with-accessors ((suffix suffix)
                     (prefix prefix)
                     (prefix-width prefix-width))
        cache
      (if (null prefix)
          (progn
            (setf (left-sibling wad) nil)
            (push (max (max-line-length cache 0 (1- (start-line wad)))
                       (max-line-width wad))
                  prefix-width))
          (progn
            (setf (left-sibling wad) (first prefix))
            (setf (right-sibling (first prefix)) wad)
            (push (max (first prefix-width)
                       (max-line-length
                        cache
                        (1+ (end-line (first prefix)))
                        (1- (start-line wad)))
                       (max-line-width wad))
                  prefix-width)))
      (if (null suffix)
          (setf (right-sibling wad) nil)
          (progn (setf (right-sibling wad) (first suffix))
                 (setf (left-sibling (first suffix)) wad)))
      (compute-absolute-line-numbers wad)
      (push wad prefix))))

(defun gap-start (cache)
  (if (null (prefix cache))
      0
      (1+ (end-line (first (prefix cache))))))

(defun gap-end (cache)
  (if (null (suffix cache))
      (1- (line-count cache))
      (1- (start-line (first (suffix cache))))))

(defun total-width (cache)
  (max (if (null (prefix-width cache)) 0 (first (prefix-width cache)))
       (max-line-length cache (gap-start cache) (gap-end cache))
       (if (null (suffix-width cache)) 0 (first (suffix-width cache)))))

(defun pop-from-worklist (cache)
  (pop (worklist cache)))

(defun push-to-worklist (cache wad)
  (push wad (worklist cache)))

(defun pop-from-residue (cache)
  (pop (residue cache)))

(defun push-to-residue (cache wad)
  (push wad (residue cache)))

(defgeneric suffix-to-prefix (cache)
  (:method ((cache cache))
    (push-to-prefix cache (pop-from-suffix cache))))

(defgeneric prefix-to-suffix (cache)
  (:method ((cache cache))
    (assert (not (null (prefix cache))))
    (push-to-suffix cache (pop-from-prefix cache))))

(defun move-to-residue (cache)
  (push-to-residue cache (pop-from-worklist cache)))

(defun finish-scavenge (cache)
  (loop until (null (worklist cache))
        do (move-to-residue cache))
  (setf (residue cache)
        (nreverse (residue cache))))

;;; This function is called by the three operations that handle
;;; modifications.  The first time this function is called, we must
;;; position the prefix and the suffix according to the number of
;;; lines initially skipped.
(defun ensure-update-initialized (cache)
  ;; As long as there are wads on the prefix that do not completely
  ;; precede the number of skipped lines, move them to the suffix.
  (loop while (and (not (null (prefix cache)))
                   (>= (end-line (first (prefix cache)))
                       (line-counter cache)))
        do (prefix-to-suffix cache))
  ;; As long as there are wads on the suffix that completely precede
  ;; the number of skipped lines, move them to the prefix.
  (loop while (and (not (null (suffix cache)))
                   (< (end-line (first (suffix cache)))
                      (line-counter cache)))
        do (suffix-to-prefix cache)))

;;; Return true if and only if either there are no more wads, or the
;;; first wad starts at a line that is strictly greater than
;;; LINE-NUMBER.
(defun next-wad-is-beyond-line-p (cache line-number)
  (with-accessors ((suffix suffix) (worklist worklist)) cache
    (if (null worklist)
        (or (null suffix)
            (> (start-line (first suffix)) line-number))
        (> (start-line (first worklist)) line-number))))

;;; Return true if and only if LINE-NUMBER is one of the lines of WAD.
;;; The START-LINE of WAD is an absolute line number.
(defun line-is-inside-wad-p (wad line-number)
  (<= (start-line wad)
      line-number
      (+ (start-line wad) (height wad))))

;;; Add INCREMENT to the absolute line number of every wad on the
;;; worklist, and of the first wad of the suffix, if any.
(defun adjust-worklist-and-suffix (cache increment)
  (loop for wad in (worklist cache)
        do (incf (start-line wad) increment))
  (unless (null (suffix cache))
    (incf (start-line (first (suffix cache))) increment)))

;;; If the worklist is empty then move a wad from the suffix to the
;;; worklist (in that case, it is known that the suffix is not empty).
(defun ensure-worklist-not-empty (cache)
  (with-accessors ((worklist worklist)) cache
    (when (null worklist)
      (push-to-worklist cache (pop-from-suffix cache)))))

;;; When this function is called, there is at least one wad, either on
;;; the work list or on the suffix that must be processed, i.e., that
;;; wad either entirely precedes LINE-NUMBER (so that it should be
;;; moved to the residue), or it straddles the line with that line
;;; number, so that it must be taken apart.
(defun process-next-wad (cache line-number)
  (with-accessors ((worklist worklist)) cache
    (ensure-worklist-not-empty cache)
    (let ((wad (pop-from-worklist cache)))
      (if (line-is-inside-wad-p wad line-number)
          (let ((children (children wad)))
            (make-absolute children (start-line wad))
            (setf worklist (append children worklist)))
          (push-to-residue cache wad)))))

(defun handle-modified-line (cache line-number)
  (let* ((cluffer-line (flx:element* (cluffer-lines cache) line-number))
         (string       (coerce (cluffer:items cluffer-line) 'string)))
    (setf (flx:element* (lines cache) line-number) string))
  (loop until (next-wad-is-beyond-line-p cache line-number)
        do (process-next-wad cache line-number)))

(defun handle-inserted-line (cache line-number)
  (loop until (next-wad-is-beyond-line-p cache (1- line-number))
        do (process-next-wad cache line-number))
  (adjust-worklist-and-suffix cache 1))

(defun handle-deleted-line (cache line-number)
  (loop until (next-wad-is-beyond-line-p cache line-number)
        do (process-next-wad cache line-number))
  (adjust-worklist-and-suffix cache -1))

;;; Take into account modifications to the buffer by destroying the
;;; parts of the cache that are no longer valid, while keeping parse
;;; results that are not affected by such modifications.
(defun scavenge (cache)
  (let ((buffer (cluffer-buffer cache))
        (cache-initialized-p nil))
    (with-accessors ((lines lines)
                     (cluffer-lines cluffer-lines)
                     (line-counter line-counter))
        cache
      (setf line-counter 0)
      (labels ((ensure-cache-initialized ()
                 (unless cache-initialized-p
                   (setf cache-initialized-p t)
                   (ensure-update-initialized cache)))
               ;; Line deletion
               (delete-cache-line ()
                 (flx:delete* lines line-counter)
                 (flx:delete* cluffer-lines line-counter)
                 (handle-deleted-line cache line-counter))
               (remove-deleted-lines (line)
                 ;; Look at cache lines starting at LINE-COUNTER. Delete
                 ;; all cache lines that do not have LINE as their
                 ;; associated cluffer line. Those lines correspond to
                 ;; deleted lines between the previously processed line
                 ;; and LINE.
                 (loop for cache-line = (flx:element* lines line-counter)
                       for cluffer-line
                         = (flx:element* cluffer-lines line-counter)
                       until (eq line cluffer-line)
                       do (delete-cache-line)))
               ;; Handlers for Cluffer's update protocol events.
               (skip (count)
                 (incf line-counter count))
               (modify (line)
                 (ensure-cache-initialized)
                 (remove-deleted-lines line)
                 (handle-modified-line cache line-counter)
                 (incf line-counter))
               (create (line)
                 (ensure-cache-initialized)
                 (let* ((string (coerce (cluffer:items line) 'string)))
                   (flx:insert* lines line-counter string)
                   (flx:insert* cluffer-lines line-counter line))
                 (handle-inserted-line cache line-counter)
                 (incf line-counter))
               (sync (line)
                 (remove-deleted-lines line)
                 (incf line-counter)))
        ;; Run update protocol. The handler functions defined above
        ;; change the cache lines and the worklist so that they
        ;; correspond to the new buffer state.
        (setf (time-stamp cache)
              (cluffer:update buffer
                              (time-stamp cache)
                              #'sync #'skip #'modify #'create))
        ;; Remove trailing cache lines after the last
        ;; skipped/modified/... cache line, that no longer correspond
        ;; to existing lines in the cluffer buffer.
        (loop while (< line-counter (flx:nb-elements lines))
              do (delete-cache-line)))))
  (finish-scavenge cache))

;;; Given a cache, return the number of lines contained in the cache.
(defgeneric line-count (cache))

(defmethod line-count ((cache cache))
  (flx:nb-elements (lines cache)))

;;; Given a cache and a line number, return the number of items in the
;;; line with that line number.
(defgeneric line-length (cache line-number))

(defmethod line-length ((cache cache) line-number)
  (length (flx:element* (lines cache) line-number)))

;;; Given a cache, a line number an item number within that line,
;;; return the item at that position in that line.
(defgeneric item (cache line-number item-number))

(defmethod item ((cache cache) line-number item-number)
  (aref (flx:element* (lines cache) line-number) item-number))

;;; Given a cache and a line number, return the contents of that line
;;; as a vector if items.
(defgeneric line-contents (cache line-number))

(defmethod line-contents ((cache cache) line-number)
  (flx:element* (lines cache) line-number))

;;; This :BEFORE method on the slot accessor
;;; ABSOLUTE-START-LINE-NUMBER makes sure the slot is on the prefix
;;; before the primary method is called, so that the absolute start
;;; line numbers are guaranteed to be computed.
(defmethod absolute-start-line-number :before ((wad wad))
  ;; First, we find the top-level wad that this wad either is or that
  ;; this wad is a descendant of.
  (let ((top-level-wad wad))
    (loop until (null (parent top-level-wad))
          do (setf top-level-wad (parent top-level-wad)))
    ;; Then make sure WAD is on prefix. 
    (loop with cache = (cache top-level-wad)
          for suffix = (suffix cache)
          until (null suffix)
          until (and
                 ;; If WAD is relative, then it is definitely not on
                 ;; the prefix.
                 (not (relative-p wad))
                 ;; But it can also be the first wad on the suffix,
                 ;; because then it is absolute and not on the prefix.
                 (not (eq (first suffix) top-level-wad)))
          do (suffix-to-prefix cache))))

(defun map-empty-area
    (cache first-line start-column last-line end-column space-function)
  (when (or (> last-line first-line)
            (and (= last-line first-line)
                 (> end-column start-column)))
    (if (= first-line last-line)
        (funcall space-function first-line start-column end-column)
        (progn 
          ;; Handle the first line.
          (let ((line-length (line-length cache first-line)))
            (when (> line-length start-column)
              (funcall space-function first-line start-column line-length)))
          ;; Handle all remaining lines except the last one.
          (loop for line-number from (1+ first-line) below last-line
                for line-length = (line-length cache line-number)
                when (> line-length 0)
                  do (funcall space-function line-number 0 line-length))
          ;; Handle the last line.
          (when (> end-column 0)
            (funcall space-function last-line 0 end-column))))))

(defun map-wads-and-spaces
    (cache first-line last-line wad-function space-function)
  ;; Make sure no wad on the suffix starts at or before LAST-LINE.
  (loop until (null (suffix cache))
        while (<= (start-line (first (suffix cache))) last-line)
        do (suffix-to-prefix cache))
  ;; Find a suffix of the prefix (i.e., a prefix of wads in the
  ;; buffer) such that it is not the case that the first wad of the
  ;; prefix (i.e., the last wad of the buffer prefix) starts entirely
  ;; after LAST-LINE.
  (let ((remaining
          (loop for remaining on (prefix cache)
                when (<= (start-line (first remaining)) last-line)
                  return remaining)))
    (if (null remaining)
        (let ((line-length (line-length cache last-line)))
          (map-empty-area
           cache first-line 0 last-line line-length space-function))
        (progn (when (<= (end-line (first remaining)) last-line)
                 (map-empty-area
                  cache
                  (end-line (first remaining))
                  (end-column (first remaining))
                  last-line
                  (line-length cache last-line)
                  space-function))
               (loop for (wad2 wad1) on remaining
                     do (funcall wad-function wad2)
                     until (or (null wad1)
                               (< (end-line wad1) first-line))
                     do (map-empty-area
                         cache
                         (end-line wad1)
                         (end-column wad1)
                         (start-line wad2)
                         (start-column wad2)
                         space-function)
                     finally
                        (if (null wad1)
                            (map-empty-area
                             cache
                             0 0
                             (start-line wad2)
                             (start-column wad2)
                             space-function)
                            (map-empty-area
                             cache
                             (end-line wad1)
                             (end-column wad1)
                             (start-line wad2)
                             (start-column wad2)
                             space-function)))))))
