;; -*- mode: lisp -*-

(defmacro bind (list value)
  (if (list? value)
      (do (local v (make-id))
	  `(do (local ,v ,value)
	       ,@(bind1 list value)))
    `(do ,@(bind1 list value))))

(defmacro at (arr i)
  (if (and (= current-target 'lua) (number? i))
      (set i (+ i 1))
      (= current-target 'lua)
      (set i `(+ ,i 1)))
  `(get ,arr ,i))

(defmacro across ((list v i start) body...)
  (local l (make-id))
  (set i (or i (make-id)))
  (set start (or start 0))
  `(do (local ,i ,start)
       (local ,l ,list)
       (while (< ,i (length ,l))
	 (local ,v (at ,l ,i))
	 ,@body
	 (set ,i (+ ,i 1)))))

(defmacro make-set (elements...)
  (local form '(table))
  (across (elements x)
    (push form x)
    (push form true))
  form)

(defun vararg? (name)
  (= (sub name (- (length name) 3) (length name)) "..."))

(defun bind1 (list value)
  (local forms ())
  (across (list x i)
    (if (list? x)
	(set forms (join forms (bind1 x `(at ,value ,i))))
        (vararg? x)
	(do (local v (sub x 0 (- (length x) 3)))
	    (push forms `(local ,v (sub ,value ,i)))
	    break) ; no more args
      (push forms `(local ,x (at ,value ,i)))))
  forms)

;; languages

(defmacro current-language ()  `',current-target)
(set current-target (current-language))

(defmacro target (clauses...)
  (across (clauses clause)
    (if (= (at clause 0) current-target)
	(return (at clause 1)))))

;; sequences

(defun length (x)
  (target (js x.length) (lua #x)))

(defun empty? (list)
  (= (length list) 0))

(defun sub (x from upto)
  (if (string? x)
      (target
       (js (x.substring from upto))
       (lua (string.sub x (+ from 1) upto)))
    (target
     (js (x.slice from upto))
     (lua
      (do (set upto (or upto (length x)))
	  (local i from)
	  (local j 0)
	  (local x2 ())
	  (while (< i upto)
	    (set (at x2 j) (at x i))
	    (set i (+ i 1))
	    (set j (+ j 1)))
	  x2)))))

(defun map (fn arr)
  (local arr1 ())
  (across (arr x)
    (push arr1 (fn x)))
  arr1)

;; lists

(defun push (arr x)
  (target (js (arr.push x)) (lua (table.insert arr x))))

(defun pop (arr)
  (target (js (arr.pop)) (lua (table.remove arr))))

(defun last (arr)
  (at arr (- (length arr) 1)))

(defun join (a1 a2)
  (target
    (js (a1.concat a2))
    (lua
     (do (local a3 ())
	 (local i 0)
	 (local len (length a1))
	 (while (< i len)
	   (set (at a3 i) (at a1 i))
	   (set i (+ i 1)))
	 (while (< i (+ len (length a2)))
	   (set (at a3 i) (at a2 (- i len)))
	   (set i (+ i 1)))
	 a3))))

(defun reduce (f x)
  (if (empty? x) x
      (= (length x) 1) (at x 0)
    (f (at x 0) (reduce f (sub x 1)))))

(defmacro join* (xs...)
  (reduce (lambda (a b) (list 'join a b)) xs))

;; strings

(defun char (str n)
  (target (js (str.charAt n)) (lua (sub str n (+ n 1)))))

(defun find (str pattern start)
  (target
   (js (do (local i (str.indexOf pattern start))
	   (if (>= i 0) i)))
   (lua (do (if start (set start (+ start 1)))
	    (local i (string.find str pattern start true))
	    (and i (- i 1))))))

(defun split (str sep)
  (target
   (js (str.split sep))
   (lua (do (local strs ())
            (while true
              (local i (find str sep))
              (if (= i nil)
                  break
                (do (push strs (sub str 0 i))
                    (set str (sub str (+ i 1))))))
            (push strs str)
            strs))))

;; io

(target (js (set fs (require 'fs))))

(defun read-file (path)
  (target
    (js (fs.readFileSync path 'utf8))
    (lua (do (local f (io.open path))
	     (f:read '*a)))))

(defun write-file (path data)
  (target
    (js (fs.writeFileSync path data 'utf8))
    (lua (do (local f (io.open path 'w))
	     (f:write data)))))

(target (js (defun print (x) (console.log x))))

(defun write (x)
  (target (js (process.stdout.write x)) (lua (io.write x))))

(defun exit (code)
  (target (js (process.exit code)) (lua (os.exit code))))

;; predicates

(defun string? (x) (= (type x) 'string))
(defun string-literal? (x) (and (string? x) (= (char x 0) "\"")))
(defun number? (x) (= (type x) 'number))
(defun boolean? (x) (= (type x) 'boolean))
(defun composite? (x) (= (type x) (target (js 'object) (lua 'table))))
(defun atom? (x) (not (composite? x)))
(defun table? (x) (and (composite? x) (= (at x 0) nil)))
(defun list? (x) (and (composite? x) (not (= (at x 0) nil))))

;; numbers

(defun parse-number (str)
  (target
    (js (do (local n (parseFloat str))
	    (if (not (isNaN n)) n)))
    (lua (tonumber str))))

;; printing

(defun to-string (x)
  (if (= x nil) "nil"
      (boolean? x) (if x "true" "false")
      (atom? x) (cat x "")
      (table? x) "#<table>"
    (do (local str "(")
	(across (x y i)
	  (set str (cat str (to-string y)))
	  (if (< i (- (length x) 1))
	      (set str (cat str " "))))
	(cat str  ")"))))

;; misc

(target (js (defun error (msg) (throw msg) nil)))
(target (js (defun type (x) (typeof x))))

(defun apply (f args)
  (target (js (f.apply f args)) (lua (f (unpack args)))))

(set id-counter 0)

(defun make-id (prefix)
  (set id-counter (+ id-counter 1))
  (cat "_" (or prefix "") id-counter))

(set eval-result nil)

(target
 (lua (defun eval (x)
	;; lua does not allow expressions to be evaluated at the
	;; top-level
        (local y (cat "eval_result=" x))
	(local f (load y))
	(if f
	    (do (f) eval-result)
	  (do (local f,e (load x))
	      (if f (f) (error (cat e " in " x))))))))
