<template>
  <div class="container">

    <div id="inputDevices">
        <!-- <span>{{ selectedInputDeviceName }}</span> -->
        <select v-model="selectedInputDevice" @change="inputChanged">
          <option :key="id" v-for="(name, id) in audioDevices" :value="id">In: {{ name }}</option>
        </select>  
    </div>

     <div id="outputDevices"  @click="setOutputDevice" :title="selectedOutputDevice.label">
        <span>Out</span>
     </div>

    <div id="msg">
              

      <div v-if="isRecording">[ recording ]</div>
      <div v-if="!isRecording && hasEverRecorded" @click.stop="" class="rangeResetArea">
        <!-- <input @click.stop="" type="range" min="0.1" max="2.0" step="0.01" v-model="playbackRate"> -->
        <Slider v-model="playbackRate"
          label="rate"
          :min="0.13" 
          :max="2" 
          :defaultValue="1" 
          style="height: 30px; width: 400px; margin: 0 auto;" 
        />
      </div>
    </div> 

    <div id="micMonitor" ref="micMonitor" 
      :class="isRecording && 'recording'"
    ></div>

    <div id="waveform" ref="waveform" 
      @wheel="handleScrollZoom" 
      @click="handleWaveClick"
      :class="isRecording && 'recording'"
    ></div>

  <div id="instructions">
    [<strong>tab</strong>]: record toggle, 
    [<strong>space</strong>]: play toggle,
    [<strong>s</strong>]: save to file,
    [<strong>,  .  / </strong>]: slower/faster/reset,
    [<strong>drag</strong>]: create/adjust loop region,

  </div>

  </div>
</template>


<script>

const MIN_ZOOM_LEVEL = 160;
const MAX_ZOOM_LEVEL = 500;
const WAVE_HEIGHT_FACTOR = 0.8;

/*
TODO:
  - sort out damn play/pause/loop of regions inconsistencies

  - fucking kbd focus on dropdown for tab/space, can't blur the fucker

  - use last audio dev as default, localStorage, not w

  - zoom: this.wavesurfer.zoom(1...1000) ?
    - use wheel event
    - prevent leaving region on scroll

  - middle click to extend region? 'auxclick' event! (what about trackpad though?)


  NOTE: Device labels will only be shown is MediaStream is already active
  OR 'persistent permissions' have already been granted

  NOTE: Firefox config 'media.setsinkid.enabled' required to be set to 'true' to allow list of output devicess
*/

function d(...args){
  let callerName;
  try { throw new Error(); }
  catch (e) { 
      // var re = /(\w+)@|at (\w+) \(/g, st = e.stack, m;
      // re.exec(st), m = re.exec(st);
      // callerName = m[1] || m[2];
      // console.log('stack', e.stack);
      // console.dir(e.stack.split('\n'));
      callerName = e.stack.split('\n')[1].split('@')[0]
      callerName = callerName.split('/')[0];
  }
  console.log('%ccaller: %s()', 'font-size: 11pt;', callerName);
  console.log(...args);
} // d()


import WaveSurfer from 'wavesurfer.js';
import RegionsPlugin from 'wavesurfer.js/dist/plugin/wavesurfer.regions.min.js';
import MicrophonePlugin from 'wavesurfer.js/dist/plugin/wavesurfer.microphone.min.js';

// import VueSlideBar from 'vue-slide-bar';
import Slider from './ui/Slider.vue';


 export default {
  name: 'Main',
  components: { Slider },
  
  data(){
    return {
      // STATE
      wavesurfer: null,
      wavesurferMicMonitor: null,
      playbackRate: 1.0,
      playbackRateSlider: {
          data: [
          15,
          30,
          45,
          60,
          75,
          90,
          120
        ],
        range: [
          {
            label: '15 mins'
          },
          {
            label: '30 mins',
            isHide: true
          },
          {
            label: '45 mins'
          },
          {
            label: '1 hr',
            isHide: true
          },
          {
            label: '1 hr 15 mins'
          },
          {
            label: '1 hr 30 mins',
            isHide: true
          },
          {
            label: '2 hrs'
          }
        ]
      },
      zoomLevel: MIN_ZOOM_LEVEL,
      regionIsLooping: false,
      
      chunks: [],
      mediaRecorder: null,
      isRecording: false,
      hasEverRecorded: false,
      recordClass: '',
      lastRegion: null,


      audioDevices: {},
      prevAudioDevices: {}, // for keeping track of added device
      selectedInputDevice: null,
      selectedOutputDevice: {},

      keysHeld: {
        Control: false,
        Alt: false,
        Meta: false,
        Shift: false,
      },

      // poly: null,
      // recordings: [],

    };
  },


  computed: {

    recordingStatus(){
      return this.isRecording ? 'Recording...' : '';
    },

    selectedInputDeviceName(){
      return this.audioDevices[this.selectedInputDevice] || '(none)';
    },

    getMicMonitorStyle(){
      // can't just use 'v-if' because mic plugin needs to find container element or throws
      return this.isRecording ? 'display: inline-block' : 'display: none' ;
    },

    getWaveformStyle(){
      return this.isRecording ? 'display: none' : 'display: inline-block' ;
    },

  },


  watch: {
    
    playbackRate(v){
      if( v > 0.13 && v < 2.7 ){
        this.wavesurfer.setPlaybackRate(Number(v));
      } 
    },

    selectedInputDevice(v){
      this.initRecorder(); // re-initialise audio input
    },

  },


  mounted(){
    this.restoreState();

    // this.initFileManager();

    this.initFileDragDrop();

    this.getMediaDevices();
    // TODO: use new device by default?
    navigator.mediaDevices.ondevicechange = (e) => {
      console.log('media device list CHANGE', e);
      this.getMediaDevices();
    };

    this.initWavesurfer();
    this.initRecorder();

    this.$refs.waveform.focus();
  }, // mounted



  methods: {

    record(){
      this.mediaRecorder.start();
      console.log("recorder started", this.mediaRecorder.state);
      this.isRecording = true;
      this.wavesurfer.stop();
      this.wavesurfer.empty();
      this.wavesurfer.clearRegions();
      // this.wavesurfer.setPlaybackRate(1);
      this.playbackRate = 1;
      this.isRecording = true;
      
      // start the microphone
      this.wavesurferMicMonitor.microphone.start();
    },

    stopRecord(){
      this.mediaRecorder.stop();
      console.log("recorder stopped", this.mediaRecorder.state);
      this.isRecording = false;

      // start the microphone
      this.wavesurferMicMonitor.microphone.stop();
    },


   

    initWavesurfer(){

      this.wavesurfer = WaveSurfer.create({
        container: this.$refs.waveform, // << slight FOUC  
        //container: document.querySelector('#waveform'),
        waveColor: '#A8DBA8',
        progressColor: '#3B8686',

        fillParent: true,
        scrollParent: false,
        hideScrollbar: false,
        // minPxPerSec: 50,
        // pixelRatio: 1,
        // autocenter: true,

        backend: 'MediaElement',  // wavesurfer.backend  ??? MediaElement / WebAudio
        plugins: [
            
            // MicrophonePlugin.create(),

            RegionsPlugin.create({
                // regionsMinLength: 2,
                // regions: [
                //     {
                //         start: 1,
                //         end: 3,
                //         loop: false,
                //         color: 'hsla(400, 100%, 30%, 0.5)'
                //     }, {
                //         start: 5,
                //         end: 7,
                //         loop: true,
                //         color: 'hsla(200, 50%, 70%, 0.4)',
                //         minLength: 1,
                //         maxLength: 5,
                //     }
                // ],
                dragSelection: {
                    slop: 5 // 5
                }
            })  // RegionsPlugin.create()
        ]
      });

      this.wavesurfer.setHeight( window.innerHeight * WAVE_HEIGHT_FACTOR );


      // this.wavesurfer.microphone.on('deviceReady', () => {
      //   console.info('Device ready!');
      //   this.wavesurfer.microphone.start();
      // });

      //
      // if (wavesurfer.microphone.active) {
      //     wavesurfer.microphone.stop();


      this.wavesurfer.on('error', function(e) {
          console.warn(e);
      });

      this.wavesurfer.on('ready', e => {
        console.log('duration:', this.wavesurfer.getDuration() );
        // this.wavesurfer.addRegion({
        //   start: 0,
        //   end: this.wavesurfer.getDuration(),
        //   minLength: 0, 
        //   maxLength: this.wavesurfer.getDuration(),
        //   loop: true,
        //   color: 'hsla(50, 100%, 30%, 0.5)'
        // });


        this.wavesurfer.playPause(); // play once on recording end
        console.log( Object.values(this.wavesurfer.regions.list) );
      });  

      this.wavesurfer.on('region-click', e => {

        const region = this.wavesurfer.regions.list[e.id];
        
        if( this.keysHeld.Meta ){
          region.remove();
          return;  
        }

        region.play();
        region.loop = true;
        this.regionIsLooping = true;
        console.log('region click', region, e);
      });

      
      this.wavesurfer.on('zoom', r => {
        // console.log('zoom', r);
        this.zoomLevel = r;
      });


      // region-created fires as soon as you start dragging, not when finished
      this.wavesurfer.on('region-created', r => {
        console.log('region-created', r);
        console.log( Object.values(this.wavesurfer.regions.list) );
        r.color = '#ff950022';
        r.loop = true;
        r.element.children[0].style.width='1rem';
        r.element.children[0].style.opacity='0.1';
        r.element.children[1].style.width='1rem';
        r.element.children[1].style.opacity='0.1';
      }); // on region created
      // region-created fires as soon as you start dragging, not when finished



      // this.wavesurfer.on('waveform-ready', r => {
      //   console.log('waveform-ready');
      //   const lowpass = this.wavesurfer.backend.ac.createBiquadFilter();
      //   this.wavesurfer.backend.setFilter(lowpass);
      //   window.lowpass = lowpass;
      // });

      this.wavesurfer.on('region-update-end', r => {

        const duration = r.end - r.start;
        if( duration < 0.1 && !r.created ){
          r.remove();
          return;
        }

        r.created = true; // private use
        r.loop = true;
        this.regionIsLooping = true;

        console.log('region-update-end', r.color);
        console.log( Object.values(this.wavesurfer.regions.list) );
        window.r = r;
        this.lastRegion = r;

        r.play();  // playLoop?

        // if(this.wavesurfer.getCurrentTime > r.end){
        //   this.wavesurfer.setCurrentTime(r.start); 
        // }

      }); // on region created


      // region-play
      // region-in
      // region-out

      this.wavesurfer.on('region-out', r => {
        const region = this.wavesurfer.regions.list[r.id];
        // this.wavesurfer.play(region);
        // console.log('region out', region.start);
        if( this.regionIsLooping && this.lastRegion && region.id === this.lastRegion.id ){
          this.wavesurfer.setCurrentTime(region.start); //TODO: check if region has changed
        }
      });

      // this.wavesurfer.load('/bass.wav'); // Load audio from URL
      window.w   = this.wavesurfer;


      document.addEventListener('keydown', (e) => {
        
        this.keysHeld[e.key] = true;


        // console.log('down', e.code);

        switch( e.code ){
        case 'Tab':
          e.preventDefault();
          // if( rec.state === 'recording' ){
          if( this.isRecording ){
            this.stopRecord();
            this.hasEverRecorded = true;
          } else {
            this.record();
          }
          break;

          case 'ArrowLeft': 
            this.wavesurfer.setCurrentTime( this.wavesurfer.getCurrentTime() - 0.1 );
            // this.wavesurfer.play();
            break;

          case 'ArrowRight': 
            this.wavesurfer.setCurrentTime( this.wavesurfer.getCurrentTime() + 0.1 );
            // this.wavesurfer.play();
            break;

          // up/down: Zoom
          case 'ArrowUp': 
            this.wavesurfer.zoom( Math.min(MAX_ZOOM_LEVEL, this.zoomLevel+50) );
            // this.wavesurfer.play();
            this.wavesurfer.params.scrollParent = false;
            break;

          case 'ArrowDown': 
            this.wavesurfer.zoom( Math.max(MIN_ZOOM_LEVEL, this.zoomLevel-50) );
            // this.wavesurfer.play();
            this.wavesurfer.params.scrollParent = false;
            break;

        }

      });

      document.addEventListener('keyup', (e) => {
        this.keysHeld[e.key] = false;
      });



      document.addEventListener('keypress', (e) => {
        switch( e.code ){
        case 'Space':

          // return;
          // this.wavesurfer.microphone.start();
          // return;

          // if( this.lastRegion ){
          //   this.lastRegion.playLoop();
          // }
          
          if( !this.hasEverRecorded || this.isRecording ){
            // if( rec.state === 'recording' ){
            if( this.isRecording ){
              this.stopRecord();
              this.hasEverRecorded = true;
            } else {
              this.record();
            }

            return; 
          } // record if this is first

          this.wavesurfer.playPause();
          break;

        case 'KeyP':
          // let region = Object.values(this.wavesurfer.regions.list)[0];
          this.lastRegion?.playLoop();  // && this.lasregion.playLoop();
          break;

        case 'KeyR':
          // let region = Object.values(this.wavesurfer.regions.list)[1];
          // region.playLoop();
          if( this.isRecording ){
            this.hasEverRecorded = true;
            this.stopRecord();
          } else {
            this.record();
          }
          break;

        case 'KeyS':
          // TODO: save active region/whole buffer
          const wave =  bufferToWave(this.wavesurfer.backend.buffer, 0, this.wavesurfer.backend.buffer.length);
          // console.log('save', this.wavesurfer.backend.buffer.length);
          saveFile(wave, dateString() + '.wav');
          // console.log('wave', wave);
          break;

        case 'Comma':
          this.playbackRate = Math.max(0.13, this.playbackRate-0.2);
          break;
        case 'Period':
          this.playbackRate = Math.min(2, this.playbackRate+0.2);
          break;
        case 'Slash':
          this.playbackRate = 1;
          break;

        default:
          console.log('Key not handled', e.code, e);          
        }
      });

      this.initMicMonitor();

    },


    async getMediaDevices(){
      console.log('getting media devices...');
      this.prevAudioDevices = { ...this.audioDevices };

      const devices = await navigator.mediaDevices.enumerateDevices();
      
      console.log({devices});

      const newDevices = {};  
      const audioDevices = devices.filter(d => d.kind === 'audioinput');
      audioDevices.forEach(d => {
        newDevices[d.deviceId] = d.label;
        console.log('Input:', d.label);
      });

      const prevDeviceCount = Object.keys(this.prevAudioDevices).length;
      const newDeviceCount  = Object.keys(newDevices).length;
      console.log({ prevDeviceCount, newDeviceCount }); 

      if( prevDeviceCount > 0 && prevDeviceCount < newDeviceCount ){
        console.log('%cDEVICE ADDED!', 'color: green; font-weight: bold');
        // ASSUMPTION: newly-added device is always the last in the list
        this.selectedInputDevice = audioDevices[audioDevices.length - 1].deviceId;
      } else if(prevDeviceCount > newDeviceCount){
        console.log('%cDEVICE REMOVED!', 'color: red; font-weight: bold');
        // Stop using the removed device, if it was the selected device (use first device in list?)
        if( !(this.selectedInputDevice in newDevices) ){
          console.log('%cDe-selecting removed device', 'color: red; font-weight: bold');
          this.selectedInputDevice = audioDevices[0].deviceId;
        }
      } else {
        // Default to first device
        this.selectedInputDevice = audioDevices[0].deviceId;
      }
      // .catch(console.error);

      this.audioDevices = newDevices;
    },

    // WAD issue: no way to disable monitoring of microphone input! WTF?!
    // Also docs are pretty minimal, no forums for help, not great search results etc
    initWadRecorder(){
      // this.recorder = new Wad({
      //   source  : 'mic',
      //   // reverb  : {
      //   //     wet : .4
      //   // },
      //   // filter  : {
      //   //     type      : 'highpass',
      //   //     frequency : 500
      //   // },
      //   // panning : -.2
      // });
      let voice = new Wad({source: 'mic'}); // volume: 1
      this.poly = new Wad.Poly({
        // volume: 0,
        // https://www.npmjs.com/package/web-audio-daw?activeTab=readme
        recorder: {
            options: { mimeType : 'audio/webm' },
            onstop: function(event) {
                let blob = new Blob(this.recorder.chunks, { 'type' : 'audio/webm;codecs=pcm' });
                window.open(URL.createObjectURL(blob));
                // recordings.push(new Wad({source:URL.createObjectURL(blob)}))
                // recordings.push(blob);
            }
        }
      });
      this.poly.add(voice);
      voice.play();
    },


    async initRecorder(){

      if (!navigator.mediaDevices) {
        return console.error('getUserMedia not supported in this browser!');
      }

      if( Object.keys(this.audioDevices).length === 0 ){
        return;
      }

      console.log('devices', Object.keys(this.audioDevices));
      console.log('selected', this.selectedInputDevice);
      let options;
      if( this.selectedInputDevice in this.audioDevices ){
        console.log('Using selected device', this.selectedInputDeviceName);
        options = { audio: { deviceId: this.selectedInputDevice } };
      } else {
        console.log('Using default audio input device?');
        // options = { audio: true };
        options = { audio: { deviceId: this.selectedInputDevice } };
      }

      const stream = await navigator.mediaDevices.getUserMedia( options );
      // .then(stream => {

        this.mediaRecorder = new MediaRecorder(stream);
        window.rec = this.mediaRecorder;
        
        this.mediaRecorder.onstop = (e) => {
          const blob = new Blob(this.chunks, { 'type' : 'audio/webm; codecs=pcm' });
          // window.open(URL.createObjectURL(blob));
          // Provide to WaveSurfer
          const audio = new Audio();
          audio.src = URL.createObjectURL(blob);
          this.wavesurferAdd(audio);
          this.chunks = [];
        }

        this.mediaRecorder.ondataavailable = (e) => this.chunks.push(e.data);

      // })
      // .catch(err => {
      //   console.log('The following error occurred: ' + err);
      // });

    }, // initRecorder()

    wavesurferAdd( audio ){

      // this.wavesurfer.loadBlob( audio ); // doesn't work! 
      this.wavesurfer.load( audio );
      
    }, // wavesurferAdd()


    rangeClick(e){
      // d(e)
      // if( e.originalTarget.nodeName !== 'INPUT' ){
      // }
      // this.wavesurfer.setPlaybackRate(1);
      this.playbackRate = 1.0;
    },

    async setOutputDevice(){
      const dev = await navigator.mediaDevices.selectAudioOutput();
      console.log({dev});
      this.selectedOutputDevice = dev;
    },


    inputChanged(e){
      console.log('inputChanged');
      localStorage.setItem('selectedInputDevice', this.selectedInputDevice);
      this.$refs.waveform.focus();
    },

    restoreState(){
      const selected = localStorage.getItem('selectedInputDevice');
      if( selected ){
        console.log('restore', selected);
        this.selectedInputDevice = selected;
      }
    },


    handleScrollZoom(e){
      // console.log('handleScrollZoom');    
      // d(e);
      this.wavesurfer.zoom( 
        Math.max(MIN_ZOOM_LEVEL, 
          Math.min(MAX_ZOOM_LEVEL, this.zoomLevel - e.deltaY)
        )
      );
      this.wavesurfer.params.scrollParent = false;
      //  this.wavesurfer.zoom( Math.max(100, this.zoomLevel-50) );

    },

    getRegionById(id){

    },


    handleWaveClick(e){
      d(e, e.originalTarget.nodeName)
      if(e.originalTarget.nodeName !== 'REGION'){
        this.regionIsLooping = false;
      }
    },


    //  async initFileManager(){

    //   let directory;
      
    //   try {
    //       directory = await window.showDirectoryPicker({
    //           startIn: 'desktop'
    //       });

    //       for await (const entry of directory.values()) {
    //           console.log(entry.name, entry.kind);
    //           // let newEl = document.createElement('div');
    //           // newEl.innerHTML = `<strong>${entry.name}</strong> - ${entry.kind}`;
    //           // document.getElementById('folder-info').append(newEl);
    //       }
    //   } catch(e) {
    //       console.log(e);
    //   }

    // },


    initFileDragDrop(){

      document.addEventListener("dragover", (event) => {
        event.preventDefault();
      }, false);

      document.addEventListener("drop", (event) => {
        event.preventDefault();
        // d('item', event.dataTransfer.items[0])
        const file =  event.dataTransfer.files[0];

        // Latest
        if (file) {
          const reader = new FileReader();
          reader.onload = (ev) => {
            this.chunks = [];
            const audio = new Audio();
            console.log('result', ev.target.result);
            // Create a Blob providing as first argument a typed array with the file buffer
            var blob = new window.Blob([new Uint8Array(ev.target.result)]);
            audio.src = URL.createObjectURL(blob);
            const loader = this.wavesurfer.load(audio); 
            // console.log('loader', loader); // nothing
            // this.wavesurfer.addRegion({
            //   start: 0,
            //   end: this.wavesurfer.getDuration(),
            //   minLength: 0, 
            //   maxLength: this.wavesurfer.getDuration(),
            //   loop: true,
            //   color: 'hsla(50, 100%, 30%, 0.5)'
            // });
            //
            // this.wavesurfer.loadBlob(blob); 
            // ^^^ Error:
            // Error decoding audiobuffer Main.vue:246:19
            // HTTP “Content-Type” of “text/html” is not supported. Load of media resource http://localhost:5173/[object%20AudioBuffer] failed. localhost:5173
            // Cannot play media. No decoders for requested formats: text/html
          };
          reader.onerror = function (evt) {
              console.error("An error ocurred reading the file: ", evt);
          };

          // reader.readAsDataURL(file);
           reader.readAsArrayBuffer(file);
        }

        // for (let i=0; i<items.length; i++) {
        //   let item = items[i].webkitGetAsEntry(); // FF only?
        //   if (item) {
        //       // scanFiles(item, listing);
        //       d(item)
        //       // console.log(item.file());
        //
        //       item.file(file => {
        //         let reader = new FileReader();
        //         console.log('reader', file);
        //         // this.wavesurfer.load(file);
        //
        //         reader.onload = (ev) => {
        //
        // FileReader.readAsArrayBuffer()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains an ArrayBuffer representing the file's data.
        // FileReader.readAsBinaryString()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains the raw binary data from the file as a string.
        // FileReader.readAsDataURL()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains a data: URL representing the file's data.
        // FileReader.readAsText()
        // 
        //           // successCallback(reader.result);
        //           console.log('SUCCESS', reader.readyState);
        //           const blob = new Blob([new Uint8Array(reader.result)]);
        //           this.wavesurfer.loadBlob(blob);
        //           // console.log('SUCCESS', reader.result);
        //           // const blob = new Blob(reader.result);
        //           // this.wavesurfer.loadBlob(reader.result);
        // 
        //           // const audio = new Audio();
        //           // audio.src = URL.createObjectURL(blob);
        //           // this.wavesurferAdd(audio);
        //           // this.chunks = [];
        //         };
        //
        //         reader.onerror = () => {
        //           // errorCallback(reader.error);
        //           console.log('ERR', reader.error);
        //         }
        //
        //           // reader.readAsText(file);
        //           // reader.readAsBinaryString(file);
        //           reader.readAsArrayBuffer(file);
        //
        //       }, console.warn); // open each file dropped
        //   }
        // }


      }, false); // on drop


    }, // initFileDragDrop()


    initMicMonitor(){

      console.log('container', document.querySelector('#micMonitor'));

      this.wavesurferMicMonitor = WaveSurfer.create({
        container:     this.$refs.micMonitor, //document.querySelector('#micMonitor'),
        waveColor:     'orange',
        interact:      false,
        fillParent:    true,
        scrollParent:  false,
        hideScrollbar: true,
        cursorWidth:   0,
        plugins:       [ MicrophonePlugin.create() ]
      });

      this.wavesurferMicMonitor.setHeight( window.innerHeight * WAVE_HEIGHT_FACTOR );

      this.wavesurferMicMonitor.microphone.on('deviceReady', function(stream) {
          console.log('Device ready!', stream);
      });
      this.wavesurferMicMonitor.microphone.on('deviceError', function(code) {
          console.warn('Device error: ' + code);
      });

    
    },




  }, // methods


}

// https://stackoverflow.com/a/62260599
// (C) Ken Fyrstenberg / MIT license
// TODO: format is hardcoded 16bit 44khz?
function bufferToWave(abuffer, offset, len) {

  var numOfChan = abuffer.numberOfChannels,
      length = len * numOfChan * 2 + 44,
      buffer = new ArrayBuffer(length),
      view = new DataView(buffer),
      channels = [], i, sample,
      pos = 0;

  // write WAVE header
  setUint32(0x46464952);                         // "RIFF"
  setUint32(length - 8);                         // file length - 8
  setUint32(0x45564157);                         // "WAVE"

  setUint32(0x20746d66);                         // "fmt " chunk
  setUint32(16);                                 // length = 16
  setUint16(1);                                  // PCM (uncompressed)
  setUint16(numOfChan);
  setUint32(abuffer.sampleRate);
  setUint32(abuffer.sampleRate * 2 * numOfChan); // avg. bytes/sec
  setUint16(numOfChan * 2);                      // block-align
  setUint16(16);                                 // 16-bit (hardcoded in this demo)

  setUint32(0x61746164);                         // "data" - chunk
  setUint32(length - pos - 4);                   // chunk length

  // write interleaved data
  for(i = 0; i < abuffer.numberOfChannels; i++)
    channels.push(abuffer.getChannelData(i));

  while(pos < length) {
    for(i = 0; i < numOfChan; i++) {             // interleave channels
      sample = Math.max(-1, Math.min(1, channels[i][offset])); // clamp
      sample = (0.5 + sample < 0 ? sample * 32768 : sample * 32767)|0; // scale to 16-bit signed int
      view.setInt16(pos, sample, true);          // update data chunk
      pos += 2;
    }
    offset++                                     // next source sample
  }

  // create Blob
  return (URL || webkitURL).createObjectURL(new Blob([buffer], {type: "audio/wav"}));

  function setUint16(data) {
    view.setUint16(pos, data, true);
    pos += 2;
  }

  function setUint32(data) {
    view.setUint32(pos, data, true);
    pos += 4;
  }
}

// https://stackoverflow.com/a/48968694
function saveFile(fileURL, filename) {
  if (window.navigator.msSaveOrOpenBlob) {
    window.navigator.msSaveOrOpenBlob(blob, filename);
  } else {
    const a = document.createElement('a');
    document.body.appendChild(a);
    // const url = window.URL.createObjectURL(blob);
    a.href = fileURL;
    a.download = filename;
    a.click();
    setTimeout(() => {
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);
    }, 0)
  }
}

// https://stackoverflow.com/questions/10645994/how-to-format-a-utc-date-as-a-yyyy-mm-dd-hhmmss-string-using-nodejs
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat/DateTimeFormat#options
function dateString(){
  // return new Date().toISOString().replace('T', '_').replace(':', '.').replace(/\..+/, '');
  return new Date()
    .toLocaleString('default', { dateStyle: 'short', timeStyle: 'medium' })
    .replaceAll('/', '-') // ugh
    .replace(', ', '_')
    .replaceAll(':', '.')
    .replaceAll(' ', '');
}

</script>

<style>

.container {
  text-align: center;
}

#micMonitor {
  max-width: 998px;
  display: none;
  text-align: center;
}

/* #micMonitor > wave{
} */

#micMonitor.recording {
  display: block;
  display: inline-block;
  width: 100%;
}

#waveform {
  display: block;
}
#waveform.recording {
  display: none;
}

/* #waveform {
  width: 90vw;
  margin: 0 auto;
} */

/* .recording {
  border: 2px solid #ff9500e6;
  color: #ff950075; 
} */


#msg {
  z-index: 100;
  font-size: 24pt;
  width: 30wv;
  text-align: center;
  height: 10vh;
  color: #ff9500e6;

}
.rangeResetArea {
  padding: 1rem;
  display: inline-block;
}

div.rangeResetArea:hover > div {
  opacity: 1;
  color: #bbbbbb;
}

div.rangeResetArea > div {
  font-size: 1.5rem;
  transition: 0.1s;
  color: #000000; 
  /* opacity: 0; */
}

/* div.rangeResetArea:hover {
  background-color: #ffffff;
  border: 1px solid red;
} */

region {
  border-left: 1px solid #ffffff22 !important;
  border-right: 1px solid #ffffff22 !important;
}

/* .wavesurfer-handle.wavesurfer-handle-start {
  border-left: 1px solid #999999 !important;
}
.wavesurfer-handle.wavesurfer-handle-end {
  border-right: 1px solid #999999 !important;
}
*/

.wavesurfer-handle.wavesurfer-handle-start:hover {
  border-left: 1px solid #ffffffff !important;
  opacity: 1.0 !important;
  background-color: #ff950022 !important;
}
.wavesurfer-handle.wavesurfer-handle-end:hover {
  border-right: 1px solid #ffffffff !important;
  opacity: 1.0 !important;
  background-color: #ff950022 !important;
} 

.wavesurfer-handle {
  /* border: 1px solid rgba(0,0,0, 0); */
  transition: 0.17s;
}

#outputDevices {
  position: fixed;
  top: 0;
  right: 0;
  z-index: 200;
  transition: 0.3s;
  text-align: center;
  padding: 0.4rem;
  border: none;
  color: grey;
  cursor: pointer;
}

#outputDevices:hover {
  color: white;
}


#inputDevices {
  position: fixed;
  top: 0;
  left: 0;
  z-index: 200;
  transition: 1s;
  text-align: center;
  padding: 0.4rem;
}

 #inputDevices select {
  background: black;
  color: grey;
  border: 1px solid black;
  /* display: none; */
}
#inputDevices:hover select{
  border: 1px solid grey;
}

/* #inputDevices select {
  background: black;
  color: white;
  border: none;
  display: none;
}
#inputDevices:hover select, #inputDevices select:hover {
  display: block;
  border: 1px solid grey;
} */
/* 
#inputDevices label {
  display: block;
  text-align: center;
}
#inputDevices:hover label {
  display: none;
} */

#inputDevices label span {
  color: white;
}

#instructions {
  position: fixed;
  bottom: 0;
  width: 100%;
  height: 2rem;
  color: grey;
  font-size: 10pt;
}
#instructions strong{
  font-weight: bold;
  text-decoration: underline;
}
#instructions:hover {
  color: white;
}
</style>


