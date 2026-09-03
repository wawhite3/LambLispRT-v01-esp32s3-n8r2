;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;LambLisp driver for PCF8574 I2C pin expander.

(define PCF8574-IO
  (2list->dict (list
		 `(read8 ,(lambda (address)
			   (let* ((nread (Wire 'requestFrom address 1))
				  #| should check for exactly 1 byte read |#
				  )
			     (Wire.read)
			     )
			   )
			)
		 
		 `(write8 ,(lambda (address value)
			    (Wire.beginTransmission address)
			    (Wire.write value)
			    (Wire.endTransmission)
			    )
			 )
		 )
	       )
  )

(define (PCF8574 address)
  (let* ((addr   address)
	(lastIn  0)
	(lastOut 0)
	(reader (dict-ref PCF8574-IO 'read8))
	(writer (dict-ref PCF8574-IO 'write8))
	(dict (2list->dict (list
				 `(read8 ,(lambda ()
					       (set! lastIn (reader addr)
						     lastIn
						     )
					       )
					  )
				  `(write8 ,(lambda (val)
						(writer addr val)
						(set! lastOut val)
						lastOut
						)
					   )
				  )
				)
		   )
	)
    dict
    )
  )

(define pcf8574 (PCF8574 #x20))

