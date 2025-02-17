;;; closql.el --- store EIEIO objects using EmacSQL  -*- lexical-binding: t; -*-

;; Copyright (C) 2016-2018  Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Homepage: https://github.com/emacscollective/closql
;; Package-Requires: ((emacs "25.1") (emacsql-sqlite "3.0.0"))
;; Keywords: extensions

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation; either version 3 of the License,
;; or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU GPL see http://www.gnu.org/licenses.

;;; Commentary:

;; Store uniform EIEIO objects in an EmacSQL database.  SQLite is used
;; as backend.  This library imposes some restrictions on what kind of
;; objects can be stored; it isn't intended to store arbitrary objects.
;; All objects have to share a common superclass and subclasses cannot
;; add any additional instance slots.

;;; Code:

(require 'eieio)
(require 'emacsql-sqlite)

(eval-when-compile (require 'subr-x))

;;; Objects

(defclass closql-object ()
  ((closql-class-prefix  :initform nil :allocation :class)
   (closql-class-suffix  :initform nil :allocation :class)
   (closql-table         :initform nil :allocation :class)
   (closql-primary-key   :initform nil :allocation :class)
   (closql-foreign-key   :initform nil :allocation :class)
   (closql-foreign-table :initform nil :allocation :class)
   (closql-order-by      :initform nil :allocation :class)
   (closql-database      :initform nil :initarg :closql-database))
  :abstract t)

;;;; Oref

(defun eieio-oref--closql-oref (fn obj slot)
  (if (closql-object--eieio-childp obj)
      (closql-oref obj slot)
    (funcall fn obj slot)))

(advice-add 'eieio-oref :around #'eieio-oref--closql-oref)

(defun closql--oref (obj slot)
  (aref obj (eieio--slot-name-index (eieio--object-class obj) slot)))

(defun closql-oref (obj slot)
  (cl-check-type slot symbol)
  (cl-check-type obj (or eieio-object class))
  (let* ((class (cond ((symbolp obj)
                       (error "eieio-oref called on a class: %s" obj)
                       (let ((c (cl--find-class obj)))
                         (if (eieio--class-p c) (eieio-class-un-autoload obj))
                         c))
                      (t (eieio--object-class obj))))
         (c (eieio--slot-name-index class slot)))
    (if (not c)
        (if (setq c (eieio--class-slot-name-index class slot))
            (aref (eieio--class-class-allocation-values class) c)
          (slot-missing obj slot 'oref))
      (cl-check-type obj eieio-object)
      (let ((value (aref obj c))
            (class (closql--slot-get obj slot :closql-class))
            (table (closql--slot-table obj slot))
            (db    (closql--oref obj 'closql-database)))
        (cond
         (class
          (aset obj c
                (mapcar (lambda (row)
                          (closql--remake-instance class db row))
                        (emacsql db (vconcat
                                     [:select * :from $i1
                                      :where (= $i2 $s3)]
                                     (vector
                                      :order-by
                                      (or (oref-default class closql-order-by)
                                          [(asc $i4)])))
                                 (oref-default class closql-table)
                                 (oref-default class closql-foreign-key)
                                 (closql--oref
                                  obj (oref-default obj closql-primary-key))
                                 (oref-default class closql-primary-key)))))
         (table
          (if (eq value eieio-unbound)
              (let ((columns (closql--table-columns db table)))
                (aset obj c
                      (mapcar
                       (if (= (length columns) 2) #'cadr #'cdr)
                       (emacsql db [:select * :from $i1
                                    :where (= $i2 $s3)
                                    :order-by [(asc $i4)]]
                                table
                                (car columns)
                                (closql--oref
                                 obj (oref-default obj closql-primary-key))
                                (cadr columns)))))
            value))
         (t
          (eieio-barf-if-slot-unbound value obj slot 'oref)))))))

;;;; Oset

(defun eieio-oset--closql-oset (fn obj slot value)
  (if (closql-object--eieio-childp obj)
      (closql-oset obj slot value)
    (funcall fn obj slot value)))

(advice-add 'eieio-oset :around #'eieio-oset--closql-oset)

(defun closql--oset (obj slot value)
  (aset obj (eieio--slot-name-index (eieio--object-class obj) slot) value))

(defun closql-oset (obj slot value)
  (cl-check-type obj eieio-object)
  (cl-check-type slot symbol)
  (let* ((class (eieio--object-class obj))
         (c (eieio--slot-name-index class slot)))
    (if (not c)
        (if (setq c (eieio--class-slot-name-index class slot))
            (progn (eieio--validate-class-slot-value class c value slot)
                   (aset (eieio--class-class-allocation-values class) c value))
          (slot-missing obj slot 'oset value))
      (eieio--validate-slot-value class c value slot)
      (unless (eq slot 'closql-database)
        (let ((db (closql--oref obj 'closql-database)))
          (unless (or (not db) (eq db eieio-unbound))
            (closql--dset db obj slot value))))
      (aset obj c value))))

(defun closql--dset (db obj slot value)
  (let* ((key   (oref-default obj closql-primary-key))
         (id    (closql--oref obj key))
         (class (closql--slot-get obj slot :closql-class))
         (table (closql--slot-table obj slot)))
    (cond
     (class
      (error "Not implemented for closql-class slots: oset"))
     (table
      (emacsql-with-transaction db
        (let ((columns (closql--table-columns db table)))
          ;; Caller might have modified value in place.
          (closql--oset obj slot eieio-unbound)
          (let ((list1 (closql-oref obj slot))
                (list2 value)
                elt1 elt2)
            (when (= (length columns) 2)
              (setq list1 (mapcar #'list list1))
              (setq list2 (mapcar #'list list2)))
            ;; `list2' may not be sorted at all and `list1' has to
            ;; be sorted because Elisp and SQLite sort differently.
            (setq list1 (cl-sort list1 'string< :key #'car))
            (setq list2 (cl-sort list2 'string< :key #'car))
            (while (progn (setq elt1 (car list1))
                          (setq elt2 (car list2))
                          (or elt1 elt2))
              (let ((key1 (car elt1))
                    (key2 (car elt2)))
                (cond
                 ((and elt1 (or (not elt2) (string< key1 key2)))
                  (apply #'emacsql db
                         (vconcat
                          [:delete-from $i1 :where]
                          (closql--where-equal (cons id elt1) 1))
                         table
                         (cl-mapcan #'list columns (cons id elt1)))
                  (pop list1))
                 ((string= key1 key2)
                  (unless (equal elt1 elt2)
                    (cl-mapcar
                     (lambda (col val1 val2)
                       (unless (equal val1 val2)
                         (emacsql db [:update $i1 :set (= $i2 $s3)
                                      :where (and (= $i4 $s5) (= $i6 $s7))]
                                  table col val2
                                  (car  columns) id
                                  (cadr columns) key2)))
                     (cddr columns)
                     (cdr  elt1)
                     (cdr  elt2)))
                  (pop list1)
                  (pop list2))
                 (t
                  (emacsql db [:insert-into $i1 :values $v2]
                           table (vconcat (cons id elt2)))
                  (pop list2)))))))))
     (t
      (emacsql db [:update $i1 :set (= $i2 $s3) :where (= $i4 $s5)]
               (oref-default obj closql-table)
               slot
               (if (eq value eieio-unbound) 'eieio-unbound value)
               key id)))))

;;;; Slot Properties

(defun closql--slot-table (obj slot)
  (let ((tbl (closql--slot-get obj slot :closql-table)))
    (and tbl (intern (replace-regexp-in-string
                      "-" "_"
                      (symbol-name (if (symbolp tbl) tbl (car tbl))))))))

(defun closql--slot-get (object-or-class slot prop)
  (let ((s (car (cl-member slot
                           (eieio-class-slots
                            (cond ((eieio-object-p object-or-class)
                                   (eieio--object-class object-or-class))
                                  ((eieio--class-p object-or-class)
                                   object-or-class)
                                  (t
                                   (find-class object-or-class 'error))))
                           :key #'cl--slot-descriptor-name))))
    (and s (cdr (assoc prop (cl--slot-descriptor-props s))))))

(defconst closql--slot-properties '(:closql-class :closql-table))

(defun eieio-defclass-internal--set-closql-slot-props
    (cname _superclasses slots _options)
  (let ((class (cl--find-class cname)))
    (when (child-of-class-p class 'closql-object)
      (pcase-dolist (`(,name . ,slot) slots)
        (let ((slot-obj
               (car (cl-member name
                               (cl-coerce (eieio--class-slots class) 'list)
                               :key (lambda (elt) (aref elt 1))))))
          (dolist (prop closql--slot-properties)
            (let ((val (plist-get slot prop)))
              (when val
                (setf (alist-get prop (cl--slot-descriptor-props slot-obj))
                      val)))))))))

(advice-add 'eieio-defclass-internal :after
            #'eieio-defclass-internal--set-closql-slot-props)

(defun eieio--slot-override--set-closql-slot-props (old new _)
  (dolist (prop closql--slot-properties)
    (when (alist-get prop (cl--slot-descriptor-props new))
      (setf (alist-get prop (cl--slot-descriptor-props old))
            (alist-get prop (cl--slot-descriptor-props new))))))

(advice-add 'eieio--slot-override :after
            #'eieio--slot-override--set-closql-slot-props)

;;; Database

(defclass closql-database (emacsql-sqlite-connection)
  ((object-class :allocation :class)))

(cl-defmethod closql-db ((class (subclass closql-database))
                         &optional variable file debug)
  (or (let ((db (and variable (symbol-value variable))))
        (and db (emacsql-live-p db) db))
      (let ((db-init (not (and file (file-exists-p file))))
            (db (make-instance class :file file)))
        (set-process-query-on-exit-flag (oref db process) nil)
        (when debug
          (emacsql-enable-debugging db))
        (when db-init
          (closql--db-init db))
        (when variable
          (set variable db))
        db)))

(cl-defgeneric closql--db-init (db))

(cl-defmethod emacsql ((connection closql-database) sql &rest args)
  (mapcar #'closql--extern-unbound
          (apply #'cl-call-next-method connection sql
                 (mapcar (lambda (arg)
                           (if (stringp arg)
                               (let ((copy (copy-sequence arg)))
                                 (set-text-properties 0 (length copy) nil copy)
                                 copy)
                             arg))
                         args))))

(cl-defmethod closql-insert ((db closql-database) obj &optional replace)
  (closql--oset obj 'closql-database db)
  (let (alist)
    (dolist (slot (eieio-class-slots (eieio--object-class obj)))
      (setq  slot (cl--slot-descriptor-name slot))
      (let ((table (closql--slot-get obj slot :closql-table)))
        (when table
          (push (cons slot (closql-oref obj slot)) alist)
          (closql--oset obj slot eieio-unbound))))
    (emacsql-with-transaction db
      (emacsql db
               (if replace
                   [:insert-or-replace-into $i1 :values $v2]
                 [:insert-into $i1 :values $v2])
               (oref-default obj closql-table)
               (pcase-let ((`(,class ,_db . ,values)
                            (closql--intern-unbound
                             (closql--coerce obj 'list))))
                 (vconcat (cons (closql--abbrev-class
                                 (if (fboundp 'record)
                                     (eieio--class-name class)
                                   class))
                                values))))
      (pcase-dolist (`(,slot . ,value) alist)
        (closql--dset db obj slot value))))
  obj)

(cl-defmethod closql-delete ((obj closql-object))
  (let ((key (oref-default obj closql-primary-key)))
    (emacsql (closql--oref obj 'closql-database)
             [:delete-from $i1 :where (= $i2 $s3)]
             (oref-default obj closql-table)
             key
             (closql--oref obj key))))

(cl-defmethod closql-reload ((obj closql-object))
  (or (closql-get (closql--oref obj 'closql-database)
                  (closql--oref obj (oref-default obj closql-primary-key))
                  (eieio-object-class obj))
      (error "Cannot reload object")))

(cl-defmethod closql-get ((db closql-database) ident &optional class)
  (unless class
    (setq class (oref-default db object-class)))
  (when-let ((row (car (emacsql db [:select * :from $i1
                                    :where (= $i2 $s3)]
                                (oref-default class closql-table)
                                (oref-default class closql-primary-key)
                                ident))))
    (closql--remake-instance class db row t)))

(cl-defmethod closql-query ((db closql-database) &optional select pred class)
  (if select
      (let ((value (closql-select db select pred class)))
        (if (and select (symbolp select))
            (mapcar #'car value)
          value))
    (closql-entries db pred class)))

(cl-defmethod closql-entries ((db closql-database) &optional pred class)
  (unless class
    (setq class (oref-default db object-class)))
  (mapcar (lambda (row)
            (closql--remake-instance class db row))
          (closql-select db '* pred class)))

(cl-defmethod closql-select ((db closql-database) select &optional pred class)
  (unless class
    (setq class (oref-default db object-class)))
  (emacsql db
           (vconcat (if (eq select '*)
                        [:select * :from $i2]
                      [:select $i1 :from $i2])
                    (and pred
                         [:where class :in $v3])
                    (if-let ((order (oref-default class closql-order-by)))
                        (vector :order-by order)
                      [:order-by [(asc $i4)]]))
           select
           (oref-default class closql-table)
           (and pred (closql-where-class-in pred))
           (oref-default class closql-primary-key)))

(defun closql--table-columns (db table)
  (mapcar #'cadr (emacsql db (format "PRAGMA table_info(%s)" table))))

;;; Object/Row Conversion

(cl-defmethod closql--remake-instance ((class (subclass closql-object))
                                       db row &optional resolve)
  (pcase-let ((`(,abbrev . ,values)
               (closql--extern-unbound row)))
    (let* ((class-sym (closql--expand-abbrev class abbrev))
           (this (if (fboundp 'record)
                     (let* ((class-obj (eieio--class-object class-sym))
                            (obj (copy-sequence
                                  (eieio--class-default-object-cache
                                   class-obj))))
                       (setq values (apply #'vector (cons db values)))
                       (dotimes (i (length (eieio--class-slots class-obj)))
                         (aset obj (1+ i) (aref values i)))
                       obj)
                   (vconcat (list class-sym db) values))))
      (when resolve
        (closql--resolve-slots this))
      this)))

(cl-defmethod closql--resolve-slots ((obj closql-object))
  (dolist (slot (eieio-class-slots (eieio--object-class obj)))
    (setq  slot (cl--slot-descriptor-name slot))
    (when (and (not (slot-boundp obj slot))
               (or (closql--slot-get obj slot :closql-class)
                   (closql--slot-get obj slot :closql-table)))
      (closql--oset obj slot (closql-oref obj slot)))))

(defun closql--intern-unbound (row)
  (mapcar (lambda (elt)
            (if (eq elt eieio-unbound) 'eieio-unbound elt))
          row))

(defun closql--extern-unbound (row)
  (mapcar (lambda (elt)
            (if (eq elt 'eieio-unbound) eieio-unbound elt))
          row))

(defun closql--coerce (object type)
  (cl-coerce (if (and (fboundp 'recordp)
                      (recordp object))
                 (let* ((len (length object))
                        (vec (make-vector len -1)))
                   (dotimes (i len)
                     (aset vec i (aref object i)))
                   vec)
               object)
             type))

(cl-defmethod closql--abbrev-class ((class-tag symbol))
  ;; This other method is only used for old-school eieio-class-tag--*.
  (closql--abbrev-class (intern (substring (symbol-name class-tag) 17))))

(cl-defmethod closql--abbrev-class ((class (subclass closql-object)))
  (let ((name (symbol-name class))
        (prefix (oref-default class closql-class-prefix))
        (suffix (oref-default class closql-class-suffix)))
    (intern (substring name
                       (if prefix    (length prefix)    0)
                       (if suffix (- (length suffix)) nil)))))

(cl-defmethod closql--expand-abbrev ((class (subclass closql-object)) abbrev)
  (intern (concat (and (not (fboundp 'record)) "eieio-class-tag--")
                  (oref-default class closql-class-prefix)
                  (symbol-name abbrev)
                  (oref-default class closql-class-suffix))))

(defun closql--where-equal (value offset)
  (vector
   (cons 'and
         (mapcar (lambda (v)
                   (if v
                       (list '=
                             (intern (format "$i%i" (cl-incf offset)))
                             (intern (format "$s%i" (cl-incf offset))))
                     (list 'isnull
                           (intern (format "$i%i" (1- (cl-incf offset 2)))))))
                 value))))

(defun closql-where-class-in (classes)
  (vconcat
   (mapcar 'closql--abbrev-class
           (cl-mapcan (lambda (sym)
                        (let ((str (symbol-name sym)))
                          (cond ((string-match-p "--eieio-childp\\'" str)
                                 (closql--list-subclasses
                                  (intern (substring str 0 -14)) nil))
                                ((string-match-p "-p\\'" str)
                                 (list (intern (substring str 0 -2))))
                                (t
                                 (list sym)))))
                      (if (listp classes) classes (list classes))))))

(defun closql--list-subclasses (class &optional result)
  (unless (class-abstract-p class)
    (cl-pushnew class result))
  (dolist (child (eieio--class-children (cl--find-class class)))
    (setq result (closql--list-subclasses child result)))
  result)

(cl-defmethod closql--list-subabbrevs ((class (subclass closql-object))
                                       &optional wildcards)
  (cl-labels
      ((types
        (class)
        (let ((children (eieio--class-children (cl--find-class class)))
              ;; An abstract base-class may violate its own naming rules.
              (abbrev (ignore-errors (closql--abbrev-class class))))
          (nconc (and (not (class-abstract-p class)) (list abbrev))
                 (and wildcards children
                      (list (if abbrev (intern (format "%s*" abbrev)) '*)))
                 (cl-mapcan #'types children)))))
    (sort (types class) #'string<)))

(cl-defmethod closql--set-object-class ((db closql-database) obj class)
  (let* ((table (oref-default obj closql-table))
         (key   (oref-default obj closql-primary-key))
         (id    (closql--oref obj key)))
    (aset obj 0
          (if (fboundp 'record)
              (aref (copy-sequence
                     (eieio--class-default-object-cache
                      (eieio--class-object class)))
                    0)
            (intern (format "eieio-class-tag--%s" class))))
    (emacsql db [:update $i1 :set (= class $s2) :where (= $i3 $s4)]
             table
             (closql--abbrev-class class)
             key id)))

;;; Experimental

(defun closql--iref (obj slot)
  (pcase-let*
      ((db (closql--oref obj 'closql-database))
       (`(,d-table ,i-table)
        (closql--slot-tables obj slot))
       (d-cols (closql--table-columns db d-table))
       (i-cols (closql--table-columns db i-table))
       (obj-id (closql--oref obj (oref-default obj closql-primary-key))))
    (emacsql db (format "\
SELECT DISTINCT %s FROM %s AS d, %s AS i
WHERE d.%s = i.%s AND d.%s = '%S';"
                (mapconcat (apply-partially #'format "i.%s")
                           (cddr i-cols) ", ")
                d-table
                i-table
                (cadr d-cols)
                (cadr i-cols)
                (car  d-cols)
                obj-id))))

(defun closql--slot-tables (obj slot)
  (let ((tbls (closql--slot-get obj slot :closql-table)))
    (unless (listp tbls)
      (error "%s isn't an indirect slot" slot))
    (pcase-let ((`(,d-tbl ,i-tbl) tbls))
      (list (intern (replace-regexp-in-string "-" "_" (symbol-name d-tbl)))
            (intern (replace-regexp-in-string "-" "_" (symbol-name i-tbl)))))))

;;; Utilities

(defun closql-format (object string &rest slots)
  "Format a string out of a format STRING and an OBJECT's SLOTS.

STRING is a format-string like for `format'.  OBJECT is an Eieio
object and SLOTS are slots of that object, their values are used
like `format' uses its OBJECTS arguments (which are unrelated to
this function's OBJECT argument, they just have similar names).

While this function does not have much to do with the purpose of
`closql', it is being defined here anyway because Eieio does not
define a similar function under a more appropriate name such as
`eieio-format'."
  (apply #'format string
         (mapcar (lambda (slot) (eieio-oref object slot)) slots)))

;;; _
(provide 'closql)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; closql.el ends here
