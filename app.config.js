// The Apple signing team is personal: set APPLE_TEAM_ID in .env.local (not committed), which Expo loads.
module.exports = ({ config }) => ({
  ...config,
  ios: { ...config.ios, ...(process.env.APPLE_TEAM_ID && { appleTeamId: process.env.APPLE_TEAM_ID }) },
});
