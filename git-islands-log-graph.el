;;; git-islands-log-graph.el --- Lanes of the commit graph -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Commits arrive newest first in topological order.  Each lane holds the
;; commit it expects next, so a commit lands in the lane waiting for it;
;; lanes that waited for it end there, its first parent continues its lane
;; and other parents get lanes of their own.  A row is drawn from straight
;; and curved segments between the lane positions at its top, middle and
;; bottom, as one SVG image cached by its shape.

;;; Code:

(require 'cl-lib)
(require 'svg)

(cl-defstruct (git-islands-graph (:constructor git-islands-graph-create))
  "The lanes after the commits seen so far."
  (lanes (make-vector 0 nil))   ; the commit each lane expects next, or nil
  (colors (make-vector 0 0))    ; each lane's color index
  (next-color 0))

(cl-defstruct (git-islands-graph-row (:constructor git-islands-graph-row-create))
  "How one commit's row is drawn."
  node        ; the lane of the commit's dot
  color       ; the dot's color index
  segments    ; (FROM-LANE FROM-Y TO-LANE TO-Y COLOR), Y 0 top, 1 middle, 2 bottom
  width)      ; lanes the row spans

(defun git-islands-graph--ensure (graph size)
  "Grow GRAPH's lanes to at least SIZE."
  (let ((lanes (git-islands-graph-lanes graph)))
    (when (< (length lanes) size)
      (setf (git-islands-graph-lanes graph) (vconcat lanes (make-vector (- size (length lanes)) nil))
            (git-islands-graph-colors graph) (vconcat (git-islands-graph-colors graph)
                                                      (make-vector (- size (length lanes)) 0))))))

(defun git-islands-graph--free (graph &optional after)
  "Return a free lane of GRAPH, preferring one right of AFTER."
  (let* ((lanes (git-islands-graph-lanes graph))
         (start (if after (1+ after) 0)))
    (or (cl-loop for i from start below (length lanes) unless (aref lanes i) return i)
        (and after (cl-loop for i from 0 below (min after (length lanes))
                            unless (aref lanes i) return i))
        (length lanes))))

(defun git-islands-graph--new-color (graph)
  "Return the next color index of GRAPH."
  (prog1 (git-islands-graph-next-color graph)
    (cl-incf (git-islands-graph-next-color graph))))

(defun git-islands-graph-step (graph hash parents)
  "Place commit HASH with PARENTS in GRAPH and return its row."
  (let* ((before (copy-sequence (git-islands-graph-lanes graph)))
         (node (or (cl-position hash before :test #'equal)
                   (git-islands-graph--free graph)))
         (_ (git-islands-graph--ensure graph (1+ node)))
         (lanes (git-islands-graph-lanes graph))
         (colors (git-islands-graph-colors graph))
         (color (if (and (< node (length before)) (equal (aref before node) hash))
                    (aref colors node)
                  (git-islands-graph--new-color graph)))
         segments)
    ;; Top half: lanes waiting for this commit end at its dot; others pass.
    (dotimes (i (length before))
      (when-let* ((expected (aref before i)))
        (push (if (equal expected hash)
                  (list i 0 node 1 (aref colors i))
                (list i 0 i 2 (aref colors i)))
              segments)))
    (dotimes (i (length lanes))
      (when (equal (aref lanes i) hash) (aset lanes i nil)))
    ;; Bottom half: the first parent continues this lane, unless another
    ;; lane already waits for it; other parents branch off.
    (when-let* ((first (car parents)))
      (if-let* ((other (cl-position first lanes :test #'equal)))
          (push (list node 1 other 2 (aref colors other)) segments)
        (aset lanes node first)
        (aset colors node color)
        (push (list node 1 node 2 color) segments)))
    (dolist (parent (cdr parents))
      (let ((lane (cl-position parent (git-islands-graph-lanes graph) :test #'equal)))
        (unless lane
          (setq lane (git-islands-graph--free graph node))
          (git-islands-graph--ensure graph (1+ lane))
          (aset (git-islands-graph-lanes graph) lane parent)
          (aset (git-islands-graph-colors graph) lane (git-islands-graph--new-color graph)))
        (push (list node 1 lane 2 (aref (git-islands-graph-colors graph) lane)) segments)))
    ;; Drop free lanes at the right edge.
    (let* ((lanes (git-islands-graph-lanes graph))
           (used (or (cl-position-if #'identity lanes :from-end t) -1)))
      (when (< (1+ used) (length lanes))
        (setf (git-islands-graph-lanes graph) (substring lanes 0 (1+ used))
              (git-islands-graph-colors graph) (substring (git-islands-graph-colors graph) 0 (1+ used)))))
    (git-islands-graph-row-create
     :node node :color color :segments (nreverse segments)
     :width (max (length before) (length (git-islands-graph-lanes graph)) (1+ node)))))

;;;; Drawing

(defvar git-islands-graph-palette
  ["#4C8DF6" "#E5A33F" "#57A64A" "#D0605B" "#9E77DB" "#3DA0A8" "#D17BB5" "#8C9196"]
  "Lane colors, as in IntelliJ's log.")

(defconst git-islands-graph-lane-width 14 "Pixels between lanes.")

(defconst git-islands-graph-padding 8
  "Pixels between the graph's last lane and the subject after it.")

(defvar git-islands-graph-cache (make-hash-table :test #'equal))

(defun git-islands-graph-color (index)
  "Return the color of lane color INDEX."
  (aref git-islands-graph-palette (mod index (length git-islands-graph-palette))))

(defun git-islands-graph-image (row height columns background &optional head)
  "Return the image of ROW, HEIGHT pixels high and COLUMNS lanes wide.
BACKGROUND rings the dot; HEAD draws it hollow, as the checked-out commit."
  (let ((key (list (git-islands-graph-row-node row) (git-islands-graph-row-color row)
                   (git-islands-graph-row-segments row) height columns background head)))
    (or (gethash key git-islands-graph-cache)
        (puthash
         key
         (let* ((lane git-islands-graph-lane-width)
                (width (+ (* lane (max columns 1)) git-islands-graph-padding))
                (svg (svg-create width height))
                (x (lambda (i) (+ (* i lane) (/ lane 2.0))))
                (y (lambda (level) (* level (/ height 2.0)))))
           (pcase-dolist (`(,from ,from-y ,to ,to-y ,color) (git-islands-graph-row-segments row))
             (let ((x1 (funcall x from)) (y1 (funcall y from-y))
                   (x2 (funcall x to)) (y2 (funcall y to-y)))
               (if (= x1 x2)
                   (svg-line svg x1 y1 x2 y2 :stroke (git-islands-graph-color color)
                             :stroke-width 1.6)
                 (let ((middle (/ (+ y1 y2) 2.0)))
                   (svg-path svg `((moveto ((,x1 . ,y1)))
                                   (curveto ((,x1 ,middle ,x2 ,middle ,x2 ,y2))))
                             :fill "none" :stroke (git-islands-graph-color color)
                             :stroke-width 1.6)))))
           (let ((cx (funcall x (git-islands-graph-row-node row)))
                 (color (git-islands-graph-color (git-islands-graph-row-color row))))
             (svg-circle svg cx (/ height 2.0) 4
                         :fill (if head background color)
                         :stroke (if head color background)
                         :stroke-width (if head 2 1.5)))
           (svg-image svg :ascent 'center))
         git-islands-graph-cache))))

(provide 'git-islands-log-graph)
;;; git-islands-log-graph.el ends here
