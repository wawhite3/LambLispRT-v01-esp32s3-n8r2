;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.

(syslog "Loading Music over buzzer\n")

(define a4 440)		;frequency of A in octave 4

(define (f n) (* 440.0 (expt 2 (/ n 12.0))))	;frequency n steps above/below A4 (equal temperament)

(define notes '(A A#Bb B C C#Db D D#Eb E F F#Gb G G#Ab))
