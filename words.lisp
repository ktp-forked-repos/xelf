;;; words.lisp --- forth-style concatenative word language for Xelf

;; Copyright (C) 2013  David O'Toole

;; Author: David O'Toole <dto@blocky.io>
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(in-package :xelf)

(defvar *words* nil)
(defvar *stack* nil)
(defvar *program* nil)

(defun pushf (x) (push x *stack*))
(defun popf () (pop *stack*))
(defun next-word () (when *program* (first *program*)))
(defun grab-next-word () (pop *program*))

(defun end-marker-p (word) 
  (and (symbolp word)
       (string= "END" (symbol-name word))))

(defun grab-until-end ()
  (let (words word)
    (block grabbing
      (loop while *program* do 
	(setf word (grab-next-word))
	(if (end-marker-p word)
	    (return-from grabbing)
	    (push word words))))
    (nreverse words)))

(defun initialize-words-maybe (&optional force)
  (when (or force (null *words*))
    ;; words are symbols so we use 'eq
    (setf *words* (make-hash-table :test 'eq))))

(initialize-words-maybe)

(defstruct word name body properties arguments)

(defun word-definition (word)
  (initialize-words-maybe)
  (gethash (make-keyword word) *words*))

(defparameter *after-define-functions* nil)

(defun run-after-define-functions (word)
  (dolist (func *after-define-functions*)
    (funcall func word)))

(defun set-word-definition (name definition)
  (assert (not (null name)))
  (assert (symbolp name)) 
  (initialize-words-maybe)
  (prog1 (setf (gethash (make-keyword name) *words*) 
	       definition)
    (run-after-define-functions name)))

(defun set-word-property (word property value)
  (let ((def (word-definition word)))
    (assert (not (null def)))
    (setf (getf (word-properties def) property)
	  value)))

(defun set-word-properties (entries)
  (dolist (entry entries)
    (apply #'set-word-property entry)))

(defun forget-word (word)
  (let ((definition (word-definition word)))
    (when (consp (word-body definition))
      (remhash word *words*))))

(defun forget-all-words ()
  (loop for word being the hash-keys of *words*
	do (forget-word word)))

(defun primitive-word-p (word)
  (getf (word-properties
	 (word-definition word))
	:primitive))

(defun reset-forth-stack ()
  (setf *stack* nil *program* nil))

(defun reset-forth-interpreter ()
  (reset-forth-stack)
  (loop for word being the hash-keys of *words* do
    (unless (primitive-word-p word)
      (forget-word word))))

(defmacro define-word (name arguments &body body)
  "Define a primitive word called NAME with Lisp code.
The BODY-forms execute later when the word NAME is executed.
The ARGUMENTS (if any) are auto-pulled from the stack by the 
interpreter."
  `(set-word-definition 
    ',name
    (make-word :name ',name
	       :arguments ',arguments
	       :properties '(:primitive t)
	       :body #'(lambda ,arguments ,@body))))

(defun define-program-word (name program)
  "Define a word as a non-primitive sequence of words."
  (set-word-definition 
   name
   (make-word :name name
	      ;; forth definitions are stored as lists
	      :body program)))

(define-word forget (word)
  (forget-word word))

;; invoking a Xelf method without any arguments.

(define-word send (method)
  (send (make-keyword method) *self*))

;; invoking a Forth method stored in the object.

(define-word call (method object)
  (let ((*self* object))
    (execute (field-value (make-keyword method) object))))

;; telling an object to execute a program

(define-word tell (program object)
  (let ((*self* object))
    (execute program)))

;;; The interpreter

(defun execute-word (word)
  (if (typep word '(or cons string number character keyword))
      ;; it's a literal. push it
      (pushf word)
      ;; otherwise try looking it up.
      (let ((definition (word-definition word)))
	(if (null definition)
	    (error "Cannot execute unknown word: ~A" word)
	    ;; found a definition. execute the body.
	    (let ((body (word-body definition)))
	      (etypecase body
		;; it's a forth definition. execute it.
		(cons
		 (let ((*program* body))
		   (loop while *program*
			 do (execute-word (pop *program*)))))
		;; it's a function word (i.e. a primitive)
		(function
		 ;; grab arguments (if any) and invoke primitive function
		 (let (arguments)
		   (dotimes (n (length (word-arguments definition)))
		     (push (popf) arguments))
		   (apply body (nreverse arguments))))))))))
  
(defun execute (program)
    (let ((*program* program))
      (loop while *program* 
	    do (execute-word (grab-next-word)))))

(defun program-from-string (string)
  (with-input-from-string (stream string)
    (let ((*read-eval* nil)
	  (*package* (project-package)))
      (loop for sexp = (read stream nil)
	    while sexp collect sexp))))

(defun execute-string (string)
  (execute (program-from-string string)))

(defun evalf (body)
  (execute (list body))
  (popf))

(defmacro forth (&rest words)
  `(execute ',words))

(defun all-words ()
  (initialize-words-maybe)
  (let ((words (loop for word being the hash-values of *words* 
		     collect (word-name word))))
    (sort words #'string<)))

(define-word end () nil)

(defmacro define-block-word (name super fields)
  `(progn 
     (define-block (,name :super ,super) ,@fields)
     (define-word ,name () (pushf (find-object ',name)))))

(defun define-method-word (method definition)
  (destructuring-bind (super &rest words) definition
    (eval `(define-word ,method () 
	     (execute (field-value ,(make-keyword method) *self*))))
    ;; install the forth definition in the prototype
    (setf (field-value (make-keyword method)
		       (find-object super))
	  words)))

(define-word define ()
  (destructuring-bind (type name &rest definition) 
      (grab-until-end)
    (or (case (make-keyword type)
	  (:word (define-program-word name definition))
	  (:method (define-method-word name definition)))
	;; define a new block with the word after DEFINE as its parent
	(let ((super type)
	      (fields (when (consp (first definition))
			(pop definition))))
	  (eval `(define-block-word ,name ,super ,fields))))))

;;; Data flow

(define-word pop () (popf))
(define-word dup (thing) (pushf thing) (pushf thing))
(define-word swap (a b) (pushf b) (pushf a))

;;; Control flow

(define-word not (boolean)
  (pushf (if boolean nil t)))

(define-word if (boolean then else)
  (execute (if boolean then else)))

(define-word every? (expressions)
  (pushf (every #'evalf expressions)))

(define-word notany? (expressions)
  (pushf (notany #'evalf expressions)))

(define-word some? (expressions)
  (pushf (some #'evalf expressions)))

(define-word each (elements body)
  (dolist (element elements)
    (pushf element)
    (execute body)))

(define-word map (elements body)
  (pushf (mapcar #'(lambda (x)
		     (pushf x)
		     (evalf body))
		 elements)))

(define-word filter (elements body)
  (pushf (remove-if-not #'evalf elements)))

;;; Accessing fields and local variables.

(define-word local ()
  (set-buffer-variable (grab-next-word) nil))

(define-word @ (var)
  (multiple-value-bind (value present-p)
      (buffer-variable var)
    (pushf 
     (if present-p
	 (buffer-variable var)
	 (field-value var *self*)))))

(define-word ! (var)
  (multiple-value-bind (value present-p)
      (buffer-variable var)
    (if present-p
	(set-buffer-variable var (popf))
	(setf (field-value var *self*) (popf)))))

;;; Object-orientation

(define-word new () (pushf (new (popf))))
(define-word self () (pushf *self*))
(define-word with () (setf *self* (popf)))

;; articles quote the next word.
;; examples:
;;    "a block"
;;    "a robot"

(define-word a () (pushf (grab-next-word)))
(define-word an () (pushf (grab-next-word)))
(define-word the () (pushf (grab-next-word)))
(define-word to () (pushf (grab-next-word)))

(defun drop-article ()
  (grab-next-word))

;;; further operations

(define-word zero? (number) (pushf (zerop number)))
(define-word even? (number) (pushf (evenp number)))
(define-word odd? (number) (pushf (oddp number)))
(define-word plus? (number) (pushf (plusp number)))
(define-word minus? (number) (pushf (minusp number)))

(define-word incr (field) 
  (assert (keywordp field))
  (incf (field-value field *self*)))

(define-word decr (field) 
  (assert (keywordp field))
  (decf (field-value field *self*)))

(define-word + (a b)
  (pushf (+ (evalf a) (evalf b))))
(define-word - (a b)
  (pushf (- (evalf a) (evalf b))))
(define-word / (a b)
  (pushf (/ (evalf a) (evalf b))))
(define-word * (a b)
  (pushf (* (evalf a) (evalf b))))

(define-word start () (start *self*))
(define-word stop () (stop *self*))

(define-word insert () (add-object (current-buffer) *self*))
(define-word delete () (remove-thing-maybe (current-buffer) *self*))
(define-word destroy () (destroy *self*))
(define-word display (image) (change-image *self* image))
(define-word show () (show *self*))
(define-word hide () (hide *self*))
(define-word visible? () (pushf (visiblep *self*)))

(define-word play (name)
  (let ((res (find-resource name)))
    (ecase (resource-type res)
      (:music (play-music name))
      (:sample (play-sample name)))))

(define-word volume! (sample volume)
  (set-sample-volume sample volume))

(define-word load-all-samples ()
  (load-all-samples))

(define-word playing (music) (play-music music :loop t))

(define-word stop-music () (halt-music))
(define-word fade-music (ms) (halt-music ms))

(define-word goto (x y) (move-to *self* x y))

(define-word move (heading distance) 
  (move *self* heading distance))

(define-word pi () (pushf pi))

(define-word degrees (n)
  (pushf (radian-angle n)))

(define-word radians ())

(define-word forward () (pushf (field-value :heading *self*)))
(define-word backward () (pushf (- pi (field-value :heading *self*))))

(define-word toward (thing) 
  (pushf (heading-to-thing *self* thing)))

(define-word distance (thing)
  (pushf (distance-between *self* thing)))
	 
(define-word left (angle) (pushf (- angle)))
(define-word right (angle) (pushf angle))

(define-word aim (heading)
  (setf (field-value :heading *self*)
	heading))

;; examples: 
;;   90 degrees left aim
;;   30 80 goto
;;   forward 10 move
;;   backward aim
;;   enemy toward aim
;;   enemy toward 2 move

(define-word drop (thing x y)
  (drop-at *self* thing x y))

(define-word here ()
  (pushf (%x *self*))
  (pushf (%y *self*)))

(define-word center ()
  (with-fields (x y width height) *self*
    (pushf (+ x (/ width 2)))
    (pushf (+ y (/ height 2)))))

(define-word leftward (x y)
  (execute `(,x :width @ - ,y))) 

(define-word rightward (x y)
  (execute `(,x :width @ + ,y))) 

(define-word above (x y)
  (execute `(,x ,y :height @ -)))

(define-word below (x y)
  (execute `(,x ,y :height @ +)))

;; examples:
;;     bullet new here drop
;;     here above goto
;;     bomb new center drop above goto

(define-word now () (pushf *updates*))
(define-word later (frames) (pushf (+ (truncate frames) *updates*)))
(define-word frames (x) (pushf (truncate x)))
(define-word seconds (x) (pushf (seconds->frames x)))

;; examples:
;;     now :started !
;;     10 frames later (
;;     2.5 seconds later

(define-word resource ()
  (xelf:add-resources
   (resource-entries-to-plists
    ;; grab name and properties
    (cons (grab-next-word) 
	  (grab-next-word)))))

(define-word image () (execute '(resource)))
(define-word sample () (execute '(resource)))
(define-word music () (execute '(resource)))
(define-word ttf () (execute '(resource)))

;; examples:
;;    image "player.png" ()
;;    sample "stomp.wav" (:volume 20)
;;    music "party.ogg" (:volume 100) 
;;    ttf "DejaVuSans.ttf" (:size 12)
;;    define myfont "DejaVuSans.ttf" end

(define-word blending (mode) (xelf:set-blending-mode mode))
(define-word filtering (mode) (xelf:use-filter mode))
(define-word color (color) (setf *color* color))
(define-word font (font) (setf *font* font))
(define-word write (string x y) (draw-string string x y))

;; examples:
;;     :additive blending
;;     :alpha blending
;;     :linear filtering
;;     :nearest filtering
;;     "white" color "sans-mono-10" font 
;;     "here i am" here below write
;;     "blue" color "another caption" center above write 

(define-word current-buffer () 
  (pushf (current-buffer)))

(define-word buffer () 
  (let ((name (grab-next-word)))
    (assert (stringp name))
    (pushf (find-buffer name :create t))))

(define-word switch-to-buffer (buffer) (switch-to-buffer buffer))

(define-word screen (height width)
  (setf *screen-height* height *screen-width* width))
(define-word no-stretch () (setf *scale-output-to-window* nil))
(define-word stretch () (setf *scale-output-to-window* t))
(define-word aa-text () (setf *use-antialiased-text* t))
(define-word no-aa-text () (setf *use-antialiased-text* nil))
(define-word no-key-repeat () (disable-key-repeat))
(define-word frame-rate! (n) (set-frame-rate n))
;; (define-word timestep! (n) (setf *dt* n))

(define-word scale (x y)
  (scale *self* x y))

(define-word colliding? (thing)
  (pushf (colliding-with *self* thing)))

(define-word project () 
  (let ((project (next-word)))
    (create-project-image 
     (if (keywordp project) 
	 (string-downcase (symbol-name project))
	 project))))

(define-word load (project)
  (load-project 
   (if (keywordp project) 
       (string-downcase (symbol-name project))
       project)))

(define-word save ()
  (save-project))

(define-word close ()
  (save-project)
  (reset))

(define-word quit () (shut-down))

(define-word debug () (setf *debug-on-error* t))
(define-word nodebug () (setf *debug-on-error* nil))

;; example: 
;;     create "myproject"
;;     open

;; (define-word view (x y height width)

;;; define forget end not if each map filter reduce get set a an the
;;; is with to send call tell is do zero? even? odd? plus? minus?
;;; new self this timer incr decr task

;;; start stop initialize destroy remove duplicate tag tag? here there
;;; it me untag contains? drop drop-at event update move forward left
;;; right backward show hide menu draw image draw resize center play
;;; collide colliding? head distance frames seconds later damage enter
;;; exit pop !heading !tags !parent !x !y !z !blend !opacity !width
;;; !height !depth !image path find

;;; resource choose random pressed? released? button key modifier
;;; control? alt? shift? report hook pointer-x pointer-y pointer
;;; !frame-rate ticks dt !dt blending filtering viewport window-x
;;; window-y window-z qwerty azerty qwertz dvorak save load project
;;; file font text lisp image music sample quad texture line box
;;; circle rectangle disc quit reset visit buffer open close

;;; joystick analog right-stick left-stick axis pressure heading
;;; right-stick? left-stick? joystick?

;;; buffer new name switch modified? window follow glide scale pause
;;; unpause select unselect selection all none cut copy paste move
;;; future present now insert delete trim clipboard here there at-pointer 

;; example:  "explode1.png" draw ("explode2.png" draw) 0.1 seconds later
;;   (destroy) enemy tell 

;;   (setf *stack* nil)
;;   (define-word foo () (format t " foo ") (pushf 3))
;;   (define-word bar () (format t " bar ") (pushf 5))
;;   (define-word baz (a b) (format t " baz ") (pushf (+ a b)))
;;   (define-word yell () (format t "WOOHOO!!"))
;;   (execute-string "foo bar baz")
;;   *stack*
;;   (execute-string "define word quux foo bar baz")
;;   (execute-string "quux")
;;   (execute '(quux 100 baz))
;;   (forth quux 100 baz)

;;   (forth define block robot (bullets hp) end) 
;;   (forth define method fire robot "KABOOM!" quux)
;;   (forth define robot vobot (shield) end)


;;   
  
;;; words.lisp ends here
