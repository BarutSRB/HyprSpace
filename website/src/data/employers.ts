export interface Employer {
  name: string;
  url: string;
  logo: string;
  contributor: string;
  handle: string;
}

export const employers: Employer[] = [
  { name: 'Bitkey', url: 'https://github.com/bitkey-oss', logo: '/credits/employers/bitkey.png', contributor: 'Naoki Ikeguchi', handle: 'siketyan' },
  { name: 'BlueLabs', url: 'https://github.com/bluelabs-eu', logo: '/credits/employers/bluelabs.png', contributor: 'Cristian Álvarez Belaustegui', handle: 'crbelaus' },
  { name: 'EPAM', url: 'https://github.com/epam', logo: '/credits/employers/epam.png', contributor: 'Aleksei Gurianov', handle: 'Guria' },
  { name: 'Finanzguru', url: 'https://github.com/finanzguru', logo: '/credits/employers/finanzguru.png', contributor: 'Janek Thomaschewski', handle: 'jthomaschewski' },
  { name: 'GitHub', url: 'https://github.com/github', logo: '/credits/employers/github.png', contributor: 'Ryan Hecht', handle: 'RyanHecht' },
  { name: 'Google', url: 'https://github.com/google', logo: '/credits/employers/google.png', contributor: 'muhammadkh', handle: 'MuhammadKh' },
  { name: 'Luxor Labs', url: 'https://luxor.tech', logo: '/credits/employers/luxor-labs.png', contributor: 'Albert Ilagan', handle: 'albertilagan' },
  { name: 'ReactSquad', url: 'https://www.reactsquad.io', logo: '/credits/employers/reactsquad.png', contributor: 'Jan Hesters', handle: 'janhesters' },
  { name: 'Spotify', url: 'https://github.com/spotify', logo: '/credits/employers/spotify.png', contributor: 'Alexander Dergachev', handle: 'Cy6erBr4in' },
  { name: 'SSW Consulting', url: 'https://github.com/SSWConsulting', logo: '/credits/employers/ssw-consulting.png', contributor: 'Matt Wicks', handle: 'wicksipedia' },
  { name: 'vhf', url: 'https://www.vhf.com', logo: '/credits/employers/vhf.png', contributor: 'Lukas Gerlinski', handle: 'lgerlinski' },
  { name: 'Viber', url: 'https://github.com/viber', logo: '/credits/employers/viber.png', contributor: 'Yuri Chukhlib', handle: 'YuriNachos' },
];
