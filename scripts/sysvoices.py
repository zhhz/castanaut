#!/usr/bin/python

# author: Martin Michel
# created: 19.05.2008

# This script is called from an AppleScript and
# returns the names of the voices installed on
# the corresponding Mac OS X system.

# Requires Mac OS X 10.5
# or a Mac OS X where PyObjC is installed:
# <http://pyobjc.sourceforge.net/>

from AppKit import NSSpeechSynthesizer

def getvoicenames():
    """I am returning the names of the voices available on Mac OS X."""
    voices = NSSpeechSynthesizer.availableVoices()
    voicenames = []
    for voice in voices:
        voiceattr = NSSpeechSynthesizer.attributesForVoice_(voice)
        voicename = voiceattr['VoiceName']
        if voicename not in voicenames:
            voicenames.append(voicename)
    return voicenames

if __name__ == '__main__':
    voicenames = getvoicenames()
    for voicename in voicenames:
        print voicename.encode('utf-8')