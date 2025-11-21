# prologue {{{
# (lazy-make-configulation
#   (task "default" ("place.py"))
#   (task "clean" () "rm place.py")
#   (task "place.py" ("gen.py")
#     "python3 gen.py > place.py"))

import math
from pprint import pprint

# |
# |
# v y  x
#  ---->


def polyline(points):
    rv = []
    for i in range(len(points)):
        if (i==0):
            rv.append([points[-1], points[i]])
        else:
            rv.append([points[i-1], points[i]])
    return rv

def genrect(x,y,w,h):
    return polyline([[x,y],[x+w,y],[x+w,y+h],[x,y+h]])

def genrectex(x,y,w,h,p=3):
    return polyline([
        [x,y+p],
        [x+p,y],
        [x+w-p,y],
        [x+w,y+p],
        [x+w,y+h-p],
        [x+w-p,y+h],
        [x+p,y+h],
        [x,y+h-p]
    ])

# variables

components = {}
outline = []
silk = []
silkb = []
labels = []
labels_back = []

# define

def edge(x, y, w, h, p = None):
    global outline
    if (p == None):
        outline += genrect(x, y, w, h)
    else:
        outline += genrectex(x, y, w, h, p)

def component(name, x, y, r = 0, flip=False):
    components[name] = {
        "location": [x, y],
        "rotation": r,
        "flip": flip,
    }

# }}}

edge(0,0,90,90)
for i in range(20):
    component("JP"+str(i+1),
              x=20,
              y=i*2.54+10,
              )
    component("JP"+str(i+21),
              x=60,
              y=50.8-i*2.54+10-2.54,
              r=180,
              )
    labels.append({
        "text":([
            "GND",
            "AD14",
            "AD13",
            "AD12",
            "AD11",
            "AD10",
            "AD9",
            "AD8",
            "AD7",
            "AD6",
            "AD5",
            "AD4",
            "AD3",
            "AD2",
            "AD1",
            "AD0",
            "NMI",
            "INTR",
            "CLK",
            "GND",
        ][i]),
        'pos':[27,10+i*2.54],
    })
    labels.append({
        "text":([
            "VDD",
            "AD15",
            "A16",
            "A17",
            "A18",
            "A19",
            "~BHE",
            "MN/~MX",
            "~RD",
            "HLDRQ",
            "HLDAK",
            "~WR",
            "~IO/M",
            "DT/~R ",
            "~DEN  ",
            "ALE   ",
            "~INTAK",
            "~TEST ",
            "READY",
            "~RESET",
        ][i]),
        'pos':[52,10+i*2.54],
    })


component("U1",
          x=32,
          y=10,
          )

component("J1",
          x=20+2.54,
          y=10,
          )
component("J2",
          x=60-2.54,
          y=10+2.54*19,
          r=180,
          )


component("J3",
          x=67,
          y=15,
          )
component("J4",
          x=67+2.54*7,
          y=15+2.54*19,
          r=180,
          )

component("H1",
          x=5,
          y=5,
          )

component("H2",
          x=85,
          y=5,
          )

component("H3",
          x=5,
          y=85,
          )

component("H4",
          x=85,
          y=85,
          )

# epilogue {{{

layout = {
    'origin': [30,30],
    'components': components,
    'outline':outline,
    'silk':silk,
    'silkb':silkb,
    'labels':labels,
    'labels_back':labels_back,
}

pprint(layout)

# }}}

# vim: set fdm=marker :
