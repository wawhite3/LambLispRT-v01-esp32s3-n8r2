var index =
[
  [
    "1 Getting Started With Real-time <em>LambLisp</em>",
    "index.html#autotoc_md1",
    [
      [
        "1.1 License",
        "index.html#license",
        null
      ],
      [
        "1.2 Prerequisites",
        "index.html#autotoc_md2",
        null
      ],
      [
        "1.3 Quick Start: Try LambLisp on Linux",
        "index.html#quick-start",
        null
      ],
      [
        "1.4 Using the REPL",
        "index.html#autotoc_md3",
        null
      ],
      [
        "1.5 Deploy to ESP32",
        "index.html#deploy-esp32",
        [
          [
            "1.5.1 Supported Platforms and Boards",
            "index.html#autotoc_md4",
            [
              [
                "1.5.1.1 ESP32 Hardware",
                "index.html#autotoc_md5",
                null
              ],
              [
                "1.5.1.2 Linux / Jetson Builds",
                "index.html#autotoc_md6",
                null
              ],
              [
                "1.5.1.3 CUDA Integration",
                "index.html#cuda-integration",
                null
              ]
            ]
          ],
          [
            "1.5.2 Build and Flash",
            "index.html#autotoc_md7",
            null
          ],
          [
            "1.5.3 Connect to the REPL",
            "index.html#autotoc_md8",
            null
          ]
        ]
      ],
      [
        "1.6 What Happens at Startup",
        "index.html#autotoc_md9",
        null
      ],
      [
        "1.7 What's in the repository?",
        "index.html#autotoc_md10",
        null
      ]
    ]
  ],
  [
    "2 <em>Lisp</em> in a nutshell",
    "index.html#autotoc_md11",
    null
  ],
  [
    "3 Why Lisp?",
    "index.html#autotoc_md12",
    null
  ],
  [
    "4 Why <em>LambLisp</em>?",
    "index.html#why-lamblisp",
    [
      [
        "4.1 Real-time control",
        "index.html#autotoc_md13",
        null
      ],
      [
        "4.2 Multi-platform",
        "index.html#autotoc_md14",
        null
      ],
      [
        "4.3 Widely recognized <em>Scheme</em> language specification",
        "index.html#autotoc_md15",
        null
      ],
      [
        "4.4 Reuse of existing C++/Arduino libraries",
        "index.html#autotoc_md16",
        null
      ],
      [
        "4.5 Adaptive real-time garbage collection",
        "index.html#autotoc_md17",
        null
      ],
      [
        "4.6 Open API for new <em>Lisp</em> primitives",
        "index.html#autotoc_md18",
        null
      ],
      [
        "4.7 Incremental over-the-air updates without reboot",
        "index.html#autotoc_md19",
        null
      ],
      [
        "4.8 First-class hierarchical dictionaries",
        "index.html#autotoc_md20",
        null
      ],
      [
        "4.9 Incremental, just-in-time compilation",
        "index.html#autotoc_md21",
        null
      ],
      [
        "4.10 Lexical scoping",
        "index.html#autotoc_md22",
        null
      ],
      [
        "4.11 Tail recursion and tail-calls",
        "index.html#autotoc_md23",
        null
      ],
      [
        "4.12 Procedures are first-class data types",
        "index.html#autotoc_md24",
        null
      ],
      [
        "4.13 Runtime collaboration with C++ code",
        "index.html#autotoc_md25",
        null
      ],
      [
        "4.14 Key feature summary",
        "index.html#autotoc_md26",
        null
      ]
    ]
  ],
  [
    "5 LambLisp Architecture Internals",
    "index.html#autotoc_md27",
    [
      [
        "5.1 Background",
        "index.html#autotoc_md28",
        [
          [
            "5.1.1 Brief history of Lisp and Scheme",
            "index.html#arch-history",
            null
          ]
        ]
      ],
      [
        "5.2 The <em>dictionary</em> type",
        "index.html#arch-dict",
        null
      ],
      [
        "5.3 Hierarchical dictionaries",
        "index.html#arch-hierdict",
        null
      ],
      [
        "5.4 Execution environment is a <em>hierarchical dictionary</em>",
        "index.html#arch-envdict",
        null
      ],
      [
        "5.5 Objects are wrappers around <em>hierarchical dictionaries</em>",
        "index.html#autotoc_md29",
        null
      ],
      [
        "5.6 Interpreter &amp; compiler organization",
        "index.html#arch-interp",
        null
      ],
      [
        "5.7 LambLisp Virtual Machine",
        "index.html#autotoc_md31",
        [
          [
            "5.7.1 Control Applications as Virtual Machines.",
            "index.html#autotoc_md32",
            null
          ],
          [
            "5.7.2 LambLisp Block Diagram",
            "index.html#autotoc_md33",
            null
          ]
        ]
      ],
      [
        "5.8 Memory Management",
        "index.html#autotoc_md34",
        [
          [
            "5.8.1 Overview",
            "index.html#autotoc_md35",
            null
          ],
          [
            "5.8.2 Cell Memory Model and List Structures",
            "index.html#autotoc_md36",
            null
          ],
          [
            "5.8.3 Garbage Collection",
            "index.html#arch-gc",
            null
          ]
        ]
      ],
      [
        "5.9 Real-time Guarantees",
        "index.html#arch-realtime",
        [
          [
            "5.9.1 GC Latency — No Stop-the-World Pauses",
            "index.html#autotoc_md37",
            null
          ],
          [
            "5.9.2 Loop Time — Bounded Control Cycle",
            "index.html#autotoc_md38",
            null
          ],
          [
            "5.9.3 Interrupt Latency — Sub-microsecond ISR",
            "index.html#autotoc_md39",
            null
          ],
          [
            "5.9.4 Asynchronous Work — Deferred Task Queue",
            "index.html#autotoc_md40",
            null
          ]
        ]
      ],
      [
        "5.10 Scalability",
        "index.html#arch-scalability",
        [
          [
            "5.10.1 Group A — Reach",
            "index.html#autotoc_md41",
            [
              [
                "5.10.1.1 Multi-Platform Support",
                "index.html#arch-multiplatform",
                null
              ],
              [
                "5.10.1.2 Network Reach",
                "index.html#autotoc_md42",
                null
              ],
              [
                "5.10.1.3 AI and Machine-to-Machine",
                "index.html#autotoc_md43",
                null
              ]
            ]
          ],
          [
            "5.10.2 Group B — Speed",
            "index.html#autotoc_md44",
            [
              [
                "5.10.2.1 Execution Tiers: AST → Bytecode → Native Code",
                "index.html#arch-pipeline",
                null
              ],
              [
                "5.10.2.2 C++ Extension",
                "index.html#autotoc_md45",
                null
              ]
            ]
          ],
          [
            "5.10.3 Group C — Footprint",
            "index.html#autotoc_md46",
            [
              [
                "5.10.3.1 Feature Footprint",
                "index.html#autotoc_md47",
                null
              ],
              [
                "5.10.3.2 Memory and GC Tuning",
                "index.html#arch-adaptive",
                null
              ],
              [
                "5.10.3.3 Code Lifecycle: Incremental Hot-Reload",
                "index.html#arch-lifecycle",
                null
              ]
            ]
          ]
        ]
      ],
      [
        "5.11 Language Internals and C++ API",
        "index.html#autotoc_md48",
        [
          [
            "5.11.1 lambda, nlambda, and macro",
            "index.html#arch-lambda",
            [
              [
                "5.11.1.1 lambda",
                "index.html#autotoc_md49",
                null
              ],
              [
                "5.11.1.2 nlambda",
                "index.html#autotoc_md50",
                null
              ],
              [
                "5.11.1.3 macro",
                "index.html#autotoc_md51",
                null
              ],
              [
                "5.11.1.4 Hygiene",
                "index.html#autotoc_md52",
                null
              ]
            ]
          ],
          [
            "5.11.2 Hash table and hashing details",
            "index.html#autotoc_md53",
            [
              [
                "5.11.2.1 Hash table sizing and collisions",
                "index.html#autotoc_md54",
                null
              ],
              [
                "5.11.2.2 The oblist",
                "index.html#autotoc_md55",
                null
              ],
              [
                "5.11.2.3 Objects and non-symbol keys",
                "index.html#autotoc_md56",
                null
              ]
            ]
          ],
          [
            "5.11.3 Lightweight object system",
            "index.html#autotoc_md57",
            null
          ],
          [
            "5.11.4 Containers",
            "index.html#autotoc_md58",
            null
          ]
        ]
      ],
      [
        "5.12 C++ Integration",
        "index.html#arch-cpp",
        [
          [
            "5.12.1 Stateless Procedures",
            "index.html#arch-mop3",
            null
          ],
          [
            "5.12.2 Stateful Objects",
            "index.html#autotoc_md59",
            null
          ],
          [
            "5.12.3 Device Patterns",
            "index.html#autotoc_md60",
            null
          ],
          [
            "5.12.4 Syntax Forms",
            "index.html#autotoc_md61",
            null
          ],
          [
            "5.12.5 Proprietary Distribution",
            "index.html#autotoc_md62",
            null
          ],
          [
            "5.12.6 Data Marshaling",
            "index.html#autotoc_md63",
            null
          ]
        ]
      ]
    ]
  ],
  [
    "6 LambLisp Extensions",
    "index.html#autotoc_md64",
    [
      [
        "6.1 Language Extensions",
        "index.html#language-extensions",
        null
      ],
      [
        "6.2 Dictionary (Environment) Operations",
        "index.html#autotoc_md65",
        null
      ],
      [
        "6.3 Structured Data",
        "index.html#structured-data",
        [
          [
            "6.3.1 JSON",
            "index.html#json",
            null
          ],
          [
            "6.3.2 CSV",
            "index.html#csv",
            null
          ],
          [
            "6.3.3 Binary framing (struct)",
            "index.html#struct",
            null
          ],
          [
            "6.3.4 Typed numeric arrays (<span class=\"tt\">array-*</span>)",
            "index.html#typed-vectors",
            [
              [
                "6.3.4.1 Array math (linear algebra)",
                "index.html#ndarray",
                null
              ]
            ]
          ]
        ]
      ],
      [
        "6.4 Arbitrary-Precision Integers (Bignums)",
        "index.html#bignum",
        null
      ],
      [
        "6.5 Cryptography",
        "index.html#crypto",
        null
      ],
      [
        "6.6 Bytecode Virtual Machine",
        "index.html#arch-bc",
        null
      ],
      [
        "6.7 Native Code Generator (NCG)",
        "index.html#arch-ncg",
        null
      ],
      [
        "6.8 Diagnostics and Development Tools",
        "index.html#autotoc_md66",
        null
      ],
      [
        "6.9 Arduino / Embedded I/O (ESP32 and compatible)",
        "index.html#autotoc_md67",
        null
      ],
      [
        "6.10 I2C (Wire)",
        "index.html#autotoc_md68",
        null
      ],
      [
        "6.11 WiFi",
        "index.html#autotoc_md69",
        [
          [
            "6.11.1 WiFi Station — Advanced",
            "index.html#wifi-station-adv",
            null
          ],
          [
            "6.11.2 WiFi Access Point (softAP)",
            "index.html#wifi-softap",
            null
          ]
        ]
      ],
      [
        "6.12 Over-the-Air Updates",
        "index.html#ota",
        [
          [
            "6.12.1 The loader wire contract (NVS)",
            "index.html#autotoc_md70",
            null
          ],
          [
            "6.12.2 The boot-confirm / rollback model",
            "index.html#autotoc_md71",
            null
          ],
          [
            "6.12.3 Example",
            "index.html#autotoc_md72",
            null
          ]
        ]
      ],
      [
        "6.13 Runtime and GC Tuning",
        "index.html#gc-tuning",
        [
          [
            "6.13.1 Timing and system",
            "index.html#autotoc_md74",
            null
          ],
          [
            "6.13.2 GC and memory tuning",
            "index.html#autotoc_md75",
            null
          ],
          [
            "6.13.3 Example",
            "index.html#autotoc_md76",
            null
          ]
        ]
      ],
      [
        "6.14 LLIP — LambLisp Interaction Protocol",
        "index.html#llip",
        [
          [
            "6.14.1 Wire Format",
            "index.html#autotoc_md77",
            null
          ],
          [
            "6.14.2 Connection Lifecycle",
            "index.html#autotoc_md78",
            null
          ],
          [
            "6.14.3 Operations",
            "index.html#autotoc_md79",
            null
          ],
          [
            "6.14.4 The eval Operation",
            "index.html#autotoc_md80",
            null
          ],
          [
            "6.14.5 Client API (<span class=\"tt\">llip-client.scm</span>)",
            "index.html#autotoc_md81",
            null
          ],
          [
            "6.14.6 Server (<span class=\"tt\">llip-server.scm</span>)",
            "index.html#autotoc_md82",
            null
          ],
          [
            "6.14.7 Transports: TCP/TLS vs Serial",
            "index.html#llip-transports",
            null
          ],
          [
            "6.14.8 Serial Transport and ARQ (<span class=\"tt\">llip-serial.scm</span>)",
            "index.html#llip-serial",
            null
          ],
          [
            "6.14.9 Device-Initiated Serving (<span class=\"tt\">llip-transport.scm</span>)",
            "index.html#llip-device-serve",
            null
          ],
          [
            "6.14.10 Command-Line Client: <span class=\"tt\">tools/llip</span>",
            "index.html#llip-cli",
            null
          ],
          [
            "6.14.11 HTTP / LLM Layer (<span class=\"tt\">llip-http.scm</span>)",
            "index.html#llip-http",
            null
          ],
          [
            "6.14.12 AI Orchestration and the Robot Stack",
            "index.html#llip-robot",
            null
          ],
          [
            "6.14.13 Security",
            "index.html#autotoc_md83",
            null
          ],
          [
            "6.14.14 Role in the Supervisory Architecture",
            "index.html#autotoc_md84",
            null
          ],
          [
            "6.14.15 Worked Example: Supervisory Control of the Freenove 4WD Car",
            "index.html#autotoc_md85",
            null
          ],
          [
            "6.14.16 Digital Twin",
            "index.html#autotoc_md86",
            null
          ],
          [
            "6.14.17 Unified Distributed Environment",
            "index.html#autotoc_md87",
            null
          ]
        ]
      ],
      [
        "6.15 LCD1602 Display",
        "index.html#autotoc_md88",
        null
      ],
      [
        "6.16 Ultrasonic Sonar (HC-SR04)",
        "index.html#ultrasonic-sonar-hc-sr04",
        null
      ],
      [
        "6.17 PCA9685 PWM Controller",
        "index.html#autotoc_md89",
        null
      ],
      [
        "6.18 WS2812 Addressable LED Strip (NeoPixel)",
        "index.html#autotoc_md90",
        null
      ],
      [
        "6.19 SPI Bus",
        "index.html#spi",
        null
      ],
      [
        "6.20 OneWire (1-Wire Bus)",
        "index.html#onewire",
        null
      ],
      [
        "6.21 Freenove 4WD Car Kit — Peripheral Summary",
        "index.html#autotoc_md91",
        null
      ],
      [
        "6.22 Camera and On-Board Display (esp32-s3-eye)",
        "index.html#camera",
        [
          [
            "6.22.1 Camera / LCD primitives (C++)",
            "index.html#autotoc_md92",
            null
          ],
          [
            "6.22.2 eye-cam.scm live-preview layer",
            "index.html#autotoc_md93",
            null
          ]
        ]
      ],
      [
        "6.23 Bundled Scheme Libraries",
        "index.html#scheme-libraries",
        [
          [
            "6.23.1 Servos and Motors (<span class=\"tt\">PCA9685.scm</span>)",
            "index.html#autotoc_md94",
            null
          ],
          [
            "6.23.2 Addressable LEDs (<span class=\"tt\">WS2812.scm</span>)",
            "index.html#autotoc_md95",
            null
          ],
          [
            "6.23.3 LED Ring Service (<span class=\"tt\">Leds.scm</span>)",
            "index.html#autotoc_md96",
            null
          ],
          [
            "6.23.4 Buzzer (<span class=\"tt\">Buzzer.scm</span>)",
            "index.html#autotoc_md97",
            null
          ],
          [
            "6.23.5 Timers (<span class=\"tt\">Timers.scm</span>)",
            "index.html#autotoc_md98",
            null
          ],
          [
            "6.23.6 I2C GPIO Expander (<span class=\"tt\">PCF8574.scm</span>)",
            "index.html#autotoc_md99",
            null
          ],
          [
            "6.23.7 Light Sensor (<span class=\"tt\">LightSensor.scm</span>)",
            "index.html#autotoc_md100",
            null
          ],
          [
            "6.23.8 I2C Bus Utilities (<span class=\"tt\">I2C.scm</span>)",
            "index.html#autotoc_md101",
            null
          ],
          [
            "6.23.9 Sonar Convenience Wrappers (<span class=\"tt\">Sonar.scm</span>)",
            "index.html#autotoc_md102",
            null
          ]
        ]
      ],
      [
        "6.24 Behaviors: Cooperative Scheduling",
        "index.html#behaviors",
        [
          [
            "6.24.1 Task Constructors",
            "index.html#autotoc_md103",
            null
          ],
          [
            "6.24.2 The Queue",
            "index.html#autotoc_md104",
            null
          ]
        ]
      ],
      [
        "6.25 ESP32 System",
        "index.html#autotoc_md105",
        [
          [
            "6.25.1 Memory Tuning: Stack Size, DMA Memory, and Pre-Reserve",
            "index.html#esp32-memory-tuning",
            null
          ]
        ]
      ],
      [
        "6.26 LambLisp Modbus Interface",
        "index.html#modbus",
        [
          [
            "6.26.1 1. Overview",
            "index.html#modbus-overview",
            null
          ],
          [
            "6.26.2 2. LambLisp as Modbus Controller",
            "index.html#modbus-controller",
            [
              [
                "6.26.2.1 2.1 Connecting",
                "index.html#modbus-controller-connect",
                null
              ],
              [
                "6.26.2.2 2.2 The Non-Blocking Request/Poll Model",
                "index.html#modbus-poll-model",
                null
              ],
              [
                "6.26.2.3 2.3 Function Codes",
                "index.html#modbus-function-codes",
                null
              ],
              [
                "6.26.2.4 2.4 Float32 Helpers",
                "index.html#modbus-float32",
                null
              ],
              [
                "6.26.2.5 2.5 Error Handling",
                "index.html#modbus-errors",
                null
              ]
            ]
          ],
          [
            "6.26.3 3. LambLisp as Modbus Peripheral",
            "index.html#modbus-peripheral",
            [
              [
                "6.26.3.1 3.1 Opening a Peripheral",
                "index.html#modbus-peripheral-open",
                null
              ],
              [
                "6.26.3.2 3.2 The Four Register Tables",
                "index.html#modbus-register-tables",
                null
              ],
              [
                "6.26.3.3 3.3 Register Accessors",
                "index.html#modbus-register-accessors",
                null
              ],
              [
                "6.26.3.4 3.4 The Serve Loop",
                "index.html#modbus-serve-loop",
                null
              ],
              [
                "6.26.3.5 3.5 Write Callbacks",
                "index.html#modbus-write-callbacks",
                null
              ]
            ]
          ],
          [
            "6.26.4 4. Platform Notes",
            "index.html#modbus-platform",
            [
              [
                "6.26.4.1 4.1 Linux (x86_64 and aarch64)",
                "index.html#modbus-linux",
                null
              ],
              [
                "6.26.4.2 4.2 ESP32-S3",
                "index.html#modbus-esp32",
                null
              ],
              [
                "6.26.4.3 4.3 Build Flag Summary",
                "index.html#modbus-build-flags",
                null
              ]
            ]
          ],
          [
            "6.26.5 5. Quick Reference",
            "index.html#modbus-quickref",
            [
              [
                "6.26.5.1 Controller Functions",
                "index.html#autotoc_md106",
                null
              ],
              [
                "6.26.5.2 Controller Function Codes (symbols for <span class=\"tt\">modbus-request</span>)",
                "index.html#autotoc_md107",
                null
              ],
              [
                "6.26.5.3 Peripheral Functions",
                "index.html#autotoc_md108",
                null
              ]
            ]
          ]
        ]
      ],
      [
        "6.27 LambLisp PROFIBUS and PROFINET Interface",
        "index.html#fieldbus",
        [
          [
            "6.27.1 1. What You Get",
            "index.html#fieldbus-what-you-get",
            null
          ],
          [
            "6.27.2 2. PROFIBUS DP as a Master",
            "index.html#profibus-master",
            [
              [
                "6.27.2.1 2.1 Opening the Bus",
                "index.html#profibus-open",
                null
              ],
              [
                "6.27.2.2 2.2 Declaring Slaves",
                "index.html#profibus-add-slave",
                null
              ],
              [
                "6.27.2.3 2.3 The Service Loop",
                "index.html#profibus-loop",
                null
              ],
              [
                "6.27.2.4 2.4 Events, Not Exceptions",
                "index.html#profibus-events",
                null
              ],
              [
                "6.27.2.5 2.5 Diagnostics and Global Control",
                "index.html#profibus-diag",
                null
              ]
            ]
          ],
          [
            "6.27.3 3. PROFIBUS DP as a Slave",
            "index.html#profibus-slave",
            [
              [
                "6.27.3.1 The baud ceiling, and why it exists",
                "index.html#profibus-baud-ceiling",
                null
              ]
            ]
          ],
          [
            "6.27.4 4. RS-485 Wiring",
            "index.html#profibus-wiring",
            null
          ],
          [
            "6.27.5 5. PROFINET",
            "index.html#profinet",
            [
              [
                "6.27.5.1 5.1 Building the daemon",
                "index.html#profinet-two-processes",
                null
              ],
              [
                "6.27.5.2 5.2 The API",
                "index.html#profinet-api",
                null
              ],
              [
                "6.27.5.3 5.3 Device model",
                "index.html#profinet-device-model",
                null
              ]
            ]
          ],
          [
            "6.27.6 6. Certification and Naming",
            "index.html#fieldbus-certification",
            null
          ],
          [
            "6.27.7 7. Build Flags",
            "index.html#fieldbus-build-flags",
            null
          ],
          [
            "6.27.8 8. Quick Reference",
            "index.html#fieldbus-quickref",
            [
              [
                "6.27.8.1 PROFIBUS DP master",
                "index.html#autotoc_md109",
                null
              ],
              [
                "6.27.8.2 PROFIBUS DP slave",
                "index.html#autotoc_md110",
                null
              ],
              [
                "6.27.8.3 PROFINET IO-Device",
                "index.html#autotoc_md111",
                null
              ],
              [
                "6.27.8.4 Error tags",
                "index.html#autotoc_md112",
                null
              ]
            ]
          ]
        ]
      ],
      [
        "6.28 Bundled Demos",
        "index.html#demos",
        [
          [
            "6.28.1 Supervisory Control (<span class=\"tt\">demo-supervisor.scm</span>)",
            "index.html#autotoc_md113",
            null
          ],
          [
            "6.28.2 Eval Sandbox (<span class=\"tt\">demo-sandbox.scm</span>)",
            "index.html#autotoc_md114",
            null
          ],
          [
            "6.28.3 Telemetry &amp; Floor Mapping (<span class=\"tt\">demo-telemetry.scm</span>)",
            "index.html#autotoc_md115",
            null
          ],
          [
            "6.28.4 Musical Notes (<span class=\"tt\">Music.scm</span>)",
            "index.html#autotoc_md116",
            null
          ],
          [
            "6.28.5 Personality (<span class=\"tt\">Personality.scm</span>)",
            "index.html#autotoc_md117",
            null
          ]
        ]
      ]
    ]
  ],
  [
    "7 Worked Examples",
    "index.html#worked-examples",
    [
      [
        "7.1 Worked Example: Autonomous Floor Mapping with the Freenove 4WD Car",
        "index.html#fwd-floor-mapping",
        [
          [
            "7.1.1 1. Overview",
            "index.html#fwd-overview",
            null
          ],
          [
            "7.1.2 2. Hardware Setup",
            "index.html#fwd-hw",
            null
          ],
          [
            "7.1.3 3. On-Board Car Code",
            "index.html#fwd-onboard",
            [
              [
                "7.1.3.1 3.1 Map Accumulator (<span class=\"tt\">floor-map.scm</span>)",
                "index.html#fwd-floor-map-scm",
                null
              ],
              [
                "7.1.3.2 3.2 Motion Primitives",
                "index.html#fwd-motion",
                null
              ],
              [
                "7.1.3.3 3.3 Autonomous Fill Behaviour",
                "index.html#fwd-autonomous",
                null
              ],
              [
                "7.1.3.4 3.4 Waypoint Navigation",
                "index.html#fwd-nav",
                null
              ],
              [
                "7.1.3.5 3.5 Bee Strategy Module",
                "index.html#fwd-bee-onboard",
                null
              ]
            ]
          ],
          [
            "7.1.4 4. Jetson Supervisor",
            "index.html#fwd-jetson",
            [
              [
                "7.1.4.1 4.1 Connections",
                "index.html#fwd-jetson-connect",
                null
              ],
              [
                "7.1.4.2 4.2 Requesting a Coverage Plan",
                "index.html#fwd-jetson-plan",
                null
              ],
              [
                "7.1.4.3 4.3 Feeding Waypoints to the Car",
                "index.html#fwd-jetson-waypoints",
                null
              ],
              [
                "7.1.4.4 4.4 Digital Twin Sync",
                "index.html#fwd-jetson-twin",
                null
              ],
              [
                "7.1.4.5 4.5 Collecting the Map",
                "index.html#fwd-jetson-collect",
                null
              ]
            ]
          ],
          [
            "7.1.5 5. Cloud Strategy Server",
            "index.html#fwd-cloud",
            [
              [
                "7.1.5.1 5.1 Boustrophedon Coverage Planner",
                "index.html#fwd-cloud-planner",
                null
              ],
              [
                "7.1.5.2 5.2 Map Store and ASCII Render",
                "index.html#fwd-cloud-mapstore",
                null
              ],
              [
                "7.1.5.3 5.3 Bee Strategy Server",
                "index.html#fwd-cloud-bee",
                null
              ]
            ]
          ],
          [
            "7.1.6 6. Running the Example",
            "index.html#fwd-run",
            [
              [
                "7.1.6.1 6.1 Start the Cloud Server",
                "index.html#fwd-run-cloud",
                null
              ],
              [
                "7.1.6.2 6.2 Flash and Start the Car",
                "index.html#fwd-run-car",
                null
              ],
              [
                "7.1.6.3 6.3 Run the Supervisor on the Jetson",
                "index.html#fwd-run-jetson",
                null
              ],
              [
                "7.1.6.4 6.4 Tuning Parameters",
                "index.html#fwd-run-tuning",
                null
              ]
            ]
          ],
          [
            "7.1.7 7. Architecture Notes",
            "index.html#fwd-arch-notes",
            [
              [
                "7.1.7.1 7.1 Why Three Tiers?",
                "index.html#fwd-why-three-tiers",
                null
              ],
              [
                "7.1.7.2 7.2 LLIP as the Universal Glue",
                "index.html#fwd-llip-glue",
                null
              ],
              [
                "7.1.7.3 7.3 Extending the Example",
                "index.html#fwd-extend",
                null
              ]
            ]
          ]
        ]
      ]
    ]
  ],
  [
    "8 LambLisp Compatibility Matrix",
    "index.html#compat-matrix",
    [
      [
        "8.1 Legend",
        "index.html#autotoc_md118",
        null
      ],
      [
        "8.2 Coverage Summary",
        "index.html#autotoc_md120",
        null
      ],
      [
        "8.3 Detailed Compatibility",
        "index.html#autotoc_md122",
        [
          [
            "8.3.1 Core Language",
            "index.html#autotoc_md123",
            null
          ],
          [
            "8.3.2 Type System",
            "index.html#autotoc_md125",
            null
          ],
          [
            "8.3.3 The Numeric Tower",
            "index.html#autotoc_md127",
            null
          ],
          [
            "8.3.4 Numbers",
            "index.html#autotoc_md129",
            null
          ],
          [
            "8.3.5 Symbols",
            "index.html#autotoc_md131",
            null
          ],
          [
            "8.3.6 Pairs and Lists",
            "index.html#autotoc_md133",
            null
          ],
          [
            "8.3.7 Characters",
            "index.html#autotoc_md135",
            null
          ],
          [
            "8.3.8 Strings",
            "index.html#autotoc_md137",
            null
          ],
          [
            "8.3.9 Vectors",
            "index.html#autotoc_md139",
            null
          ],
          [
            "8.3.10 Bytevectors",
            "index.html#autotoc_md141",
            null
          ],
          [
            "8.3.11 Control Features",
            "index.html#autotoc_md143",
            null
          ],
          [
            "8.3.12 Environments and Evaluation",
            "index.html#autotoc_md145",
            null
          ],
          [
            "8.3.13 Ports",
            "index.html#autotoc_md147",
            null
          ],
          [
            "8.3.14 Input and Output",
            "index.html#autotoc_md149",
            null
          ],
          [
            "8.3.15 System Interface",
            "index.html#autotoc_md151",
            null
          ],
          [
            "8.3.16 Exception Handling",
            "index.html#autotoc_md153",
            null
          ]
        ]
      ]
    ]
  ],
  [
    "9 LambLisp Frequently Asked Questions",
    "index.html#faq",
    [
      [
        "9.1 Getting Started",
        "index.html#autotoc_md155",
        [
          [
            "9.1.1 How do I try LambLisp right now?",
            "index.html#autotoc_md156",
            null
          ],
          [
            "9.1.2 What hardware does LambLisp run on?",
            "index.html#autotoc_md158",
            null
          ],
          [
            "9.1.3 Is LambLisp open source?",
            "index.html#autotoc_md160",
            null
          ],
          [
            "9.1.4 How do I update code without reflashing?",
            "index.html#autotoc_md162",
            null
          ]
        ]
      ],
      [
        "9.2 Concepts",
        "index.html#autotoc_md164",
        [
          [
            "9.2.1 What is a real-time control system?",
            "index.html#autotoc_md165",
            null
          ],
          [
            "9.2.2 What is LLIP?",
            "index.html#autotoc_md167",
            null
          ],
          [
            "9.2.3 How fast is LambLisp?",
            "index.html#autotoc_md169",
            null
          ],
          [
            "9.2.4 What is bytecode / NCG compilation?",
            "index.html#autotoc_md171",
            null
          ],
          [
            "9.2.5 Does the same Scheme code run on all platforms?",
            "index.html#autotoc_md173",
            null
          ]
        ]
      ],
      [
        "9.3 Language and Conformance",
        "index.html#autotoc_md175",
        [
          [
            "9.3.1 Why is it called LambLisp instead of Scheme?",
            "index.html#autotoc_md176",
            null
          ],
          [
            "9.3.2 Why no <span class=\"tt\">call-with-current-continuation</span>?",
            "index.html#autotoc_md178",
            null
          ],
          [
            "9.3.3 Where does LambLisp sit in the Lisp landscape?",
            "index.html#autotoc_md180",
            null
          ],
          [
            "9.3.4 Why not use embedded Python derivatives?",
            "index.html#autotoc_md182",
            null
          ],
          [
            "9.3.5 Why not use LLVM for native code generation?",
            "index.html#autotoc_md184",
            null
          ]
        ]
      ],
      [
        "9.4 Integration and Operation",
        "index.html#autotoc_md186",
        [
          [
            "9.4.1 What are the advantages of <em>LambLisp</em> in combination with C/C++ on micro-controllers?",
            "index.html#autotoc_md187",
            null
          ],
          [
            "9.4.2 Does LambLisp interoperate with C/C++ code?",
            "index.html#autotoc_md189",
            null
          ],
          [
            "9.4.3 Can I use LambLisp without an RTOS?",
            "index.html#autotoc_md191",
            null
          ],
          [
            "9.4.4 What is the memory footprint?",
            "index.html#autotoc_md193",
            null
          ]
        ]
      ]
    ]
  ],
  [
    "10 Other Scheme Implementations",
    "index.html#competitors",
    null
  ],
  [
    "11 Acknowledgements",
    "index.html#autotoc_md194",
    null
  ],
  [
    "12 Glossary",
    "index.html#autotoc_md195",
    null
  ],
  [
    "13 List of Figures",
    "index.html#list-of-figures",
    null
  ]
];
