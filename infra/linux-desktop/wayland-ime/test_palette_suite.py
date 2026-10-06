import json
import tempfile
import unittest
from pathlib import Path
import palette_suite

class PaletteSuiteTests(unittest.TestCase):
    def test_current_frame_only(self):
        field={'presentation':2,'committed':'日本'}
        prefix=palette_suite.PREFIX
        self.assertIsNone(palette_suite.merge_state(prefix+json.dumps({'presentation':1}),field))
        current=palette_suite.merge_state(prefix+json.dumps({'presentation':2,'query':'日本'}),field)
        self.assertEqual(current['query'],current['committed'])
        self.assertIsNone(palette_suite.merge_state(prefix+'{',field))
        self.assertIsNone(palette_suite.merge_state('',None))
    def test_profile_locator_checks_actual_opener_pixels(self):
        from PIL import Image,ImageDraw
        import gpui_probe
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'frame.png'
            image=Image.new('RGB',(960,640),(0,0,0));draw=ImageDraw.Draw(image)
            draw.rectangle((20,50,659,529),fill=(24,28,36))
            image.save(path)
            with self.assertRaises(gpui_probe.PixelsNotReady):palette_suite.locate(path)
            draw.rectangle((44,78,555,121),fill=(48,74,114));image.save(path)
            value=palette_suite.locate(path)
            self.assertEqual(value['body'],[20,50,660,530]);self.assertEqual(value['field'],[44,78,556,122])
    def test_input_catalog_is_bounded_and_excludes_background_from_ime(self):
        self.assertEqual(len(palette_suite.INPUTS),40)
        self.assertEqual(sum(stage=='background-key' for stage,key in palette_suite.INPUTS),1)
        self.assertTrue(all(key in palette_suite.KEYS for stage,key in palette_suite.INPUTS))

if __name__=='__main__':unittest.main()
